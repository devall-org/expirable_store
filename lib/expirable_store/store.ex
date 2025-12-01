defmodule ExpirableStore.Store do
  @moduledoc false

  # ===========================================================================
  # Public API
  # ===========================================================================

  def fetch(module, name, fetch_fn, refresh, scope) do
    group = make_group(scope, module, name)
    local_pid = get_local_agent(group)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      acquire_lock_and_fetch(group, fetch_fn, refresh, scope)
    else
      case Agent.get(local_pid, & &1) do
        :error ->
          acquire_lock_and_fetch(group, fetch_fn, refresh, scope)

        {:ok, _, expires_at} = entry ->
          if expired?(expires_at) do
            acquire_lock_and_fetch(group, fetch_fn, refresh, scope)
          else
            entry
          end
      end
    end
  end

  def clear(module, name, scope) do
    group = make_group(scope, module, name)

    global_trans(group, scope, fn ->
      group
      |> get_all_agents()
      |> Enum.each(fn pid ->
        try do
          Agent.stop(pid)
        catch
          _, _ -> :ok
        end
      end)
    end)

    # Wait for :pg to remove dead agents
    wait_for_pg_cleanup(group)
  end

  # ===========================================================================
  # Private implementation
  # ===========================================================================

  defp make_group(:cluster, module, name), do: {:cluster, module, name}
  defp make_group(:local, module, name), do: {:local, node(), module, name}

  defp global_trans(group, :cluster, fun) do
    :global.trans({group, self()}, fun)
  end

  defp global_trans(group, :local, fun) do
    :global.trans({group, self()}, fun, [node()])
  end

  defp acquire_lock_and_fetch(group, fetch_fn, refresh, scope) do
    global_trans(group, scope, fn ->
      local_pid = get_local_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        new_pid = create_agent(group, fetch_fn, refresh, scope)
        Agent.get(new_pid, & &1)
      else
        case Agent.get(local_pid, & &1) do
          :error ->
            new_entry = fetch_fn.()
            update_all_members(group, new_entry)
            schedule_eager_refresh(group, new_entry, fetch_fn, refresh, scope)
            new_entry

          {:ok, _, expires_at} = entry ->
            if expired?(expires_at) do
              new_entry = fetch_fn.()
              update_all_members(group, new_entry)
              schedule_eager_refresh(group, new_entry, fetch_fn, refresh, scope)
              new_entry
            else
              entry
            end
        end
      end
    end)
  end

  defp wait_for_pg_cleanup(group, attempts \\ 10) do
    case :pg.get_local_members(:expirable_store, group) do
      [] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_pg_cleanup(group, attempts - 1)

      _ ->
        :ok
    end
  end

  defp get_local_agent(group) do
    :pg.get_local_members(:expirable_store, group)
    |> List.first()
  end

  defp get_all_agents(group) do
    :pg.get_members(:expirable_store, group)
  end

  defp get_value_from_cluster(group) do
    :pg.get_members(:expirable_store, group)
    |> Enum.find_value(fn pid ->
      try do
        Agent.get(pid, & &1)
      catch
        :exit, _ -> :error
      end
    end)
  end

  defp create_agent(group, fetch_fn, refresh, scope) do
    initial_value =
      case get_value_from_cluster(group) do
        {:ok, _, _} = entry -> entry
        _ -> fetch_fn.()
      end

    spec = %{
      id: {scope, group},
      start: {Agent, :start_link, [fn -> initial_value end]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(ExpirableStore.Supervisor, spec)
    :ok = :pg.join(:expirable_store, group, pid)

    schedule_eager_refresh(group, initial_value, fetch_fn, refresh, scope)

    pid
  end

  defp update_all_members(group, new_entry) do
    group
    |> get_all_agents()
    |> Enum.each(fn pid ->
      try do
        Agent.update(pid, fn _ -> new_entry end)
      catch
        _, _ -> :ok
      end
    end)
  end

  # ===========================================================================
  # Eager refresh scheduling
  # ===========================================================================

  defp schedule_eager_refresh(_group, :error, _fetch_fn, _refresh, _scope), do: :ok
  defp schedule_eager_refresh(_group, _entry, _fetch_fn, :lazy, _scope), do: :ok
  defp schedule_eager_refresh(_group, {:ok, _, :infinity}, _fetch_fn, _refresh, _scope), do: :ok

  defp schedule_eager_refresh(group, {:ok, _value, expires_at}, fetch_fn, {:eager, opts}, scope) do
    before_ms = Keyword.fetch!(opts, :before_expiry)
    now = System.system_time(:millisecond)
    refresh_at = expires_at - before_ms
    delay = refresh_at - now

    if delay > 0 do
      spawn(fn ->
        Process.sleep(delay)
        do_eager_refresh(group, fetch_fn, {:eager, opts}, scope)
      end)
    end

    :ok
  end

  defp do_eager_refresh(group, fetch_fn, refresh, scope) do
    global_trans(group, scope, fn ->
      local_pid = get_local_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        :ok
      else
        new_entry = fetch_fn.()
        update_all_members(group, new_entry)
        schedule_eager_refresh(group, new_entry, fetch_fn, refresh, scope)
      end
    end)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp expired?(:infinity), do: false

  defp expired?(expires_at) do
    System.system_time(:millisecond) > expires_at
  end
end
