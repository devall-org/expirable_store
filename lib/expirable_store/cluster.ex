defmodule ExpirableStore.Cluster do
  @moduledoc false

  # ===========================================================================
  # Public API
  # ===========================================================================

  def fetch(module, name, fetch_fn, refresh) do
    group = {module, name}
    local_pid = get_local_agent(group)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      acquire_lock_and_fetch(group, fetch_fn, refresh)
    else
      case Agent.get(local_pid, & &1) do
        :__error__ ->
          acquire_lock_and_fetch(group, fetch_fn, refresh)

        {:__ready__, _, expires_at} = entry ->
          if expired?(expires_at) do
            acquire_lock_and_fetch(group, fetch_fn, refresh)
          else
            entry
          end
      end
    end
  end

  def clear(module, name) do
    group = {module, name}

    :global.trans({group, self()}, fn ->
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

  defp acquire_lock_and_fetch(group, fetch_fn, refresh) do
    :global.trans({group, self()}, fn ->
      local_pid = get_local_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        new_pid = create_agent(group, fetch_fn, refresh)
        Agent.get(new_pid, & &1)
      else
        case Agent.get(local_pid, & &1) do
          :__error__ ->
            new_entry = to_internal(fetch_fn.())
            update_all_members(group, new_entry)
            schedule_eager_refresh(group, new_entry, fetch_fn, refresh)
            new_entry

          {:__ready__, _, expires_at} = entry ->
            if expired?(expires_at) do
              new_entry = to_internal(fetch_fn.())
              update_all_members(group, new_entry)
              schedule_eager_refresh(group, new_entry, fetch_fn, refresh)
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
        :exit, _ -> :__error__
      end
    end)
  end

  defp create_agent(group, fetch_fn, refresh) do
    initial_value =
      case get_value_from_cluster(group) do
        {:__ready__, _, _} = entry -> entry
        _ -> to_internal(fetch_fn.())
      end

    spec = %{
      id: {:cluster, group},
      start: {Agent, :start_link, [fn -> initial_value end]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(ExpirableStore.Supervisor, spec)
    :ok = :pg.join(:expirable_store, group, pid)

    schedule_eager_refresh(group, initial_value, fetch_fn, refresh)

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

  defp schedule_eager_refresh(_group, :__error__, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh(_group, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh(group, {:__ready__, _value, expires_at}, fetch_fn, :eager) do
    now = System.system_time(:millisecond)
    ttl = expires_at - now

    if ttl > 0 do
      refresh_delay = trunc(ttl * 0.9)

      if refresh_delay > 0 do
        spawn(fn ->
          Process.sleep(refresh_delay)
          do_eager_refresh(group, fetch_fn)
        end)
      end
    end

    :ok
  end

  defp do_eager_refresh(group, fetch_fn) do
    :global.trans({group, self()}, fn ->
      local_pid = get_local_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        :ok
      else
        new_entry = to_internal(fetch_fn.())
        update_all_members(group, new_entry)
        schedule_eager_refresh(group, new_entry, fetch_fn, :eager)
      end
    end)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp expired?(expires_at) do
    System.system_time(:millisecond) > expires_at
  end

  defp to_internal({:ok, value, expires_at}), do: {:__ready__, value, expires_at}
  defp to_internal(:error), do: :__error__
end
