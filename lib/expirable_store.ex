defmodule ExpirableStore do
  @moduledoc """
  A lightweight expirable value store for Elixir.

  Provides compile-time DSL for defining expirable values with configurable
  refresh strategies and scoping (cluster-wide or local).
  """

  use Spark.Dsl, default_extensions: [extensions: [ExpirableStore.Dsl]]

  @doc """
  Fetch a stored value, returning `{:ok, value, expires_at}` on success or `:error` on failure.

  The fetch function must return `{:ok, value, expires_at}` where `expires_at` is a Unix
  timestamp in milliseconds, or `:error`.
  """
  def fetch(module, name) do
    %{fetch: fetch_fn, scope: scope, refresh: refresh} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    result =
      case scope do
        :cluster -> fetch_cluster(module, name, fetch_fn, refresh)
        :local -> fetch_local(module, name, fetch_fn, refresh)
      end

    to_external(result)
  end

  @doc """
  Fetch a stored value, raising an exception on failure.

  Returns the value directly without expiration time.
  """
  def fetch!(module, name) do
    case fetch(module, name) do
      {:ok, value, _expires_at} -> value
      :error -> raise "Failed to fetch expirable: #{inspect(name)}"
    end
  end

  @doc """
  Clear a specific expirable by name.
  """
  def clear(module, name) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    case scope do
      :cluster -> clear_cluster(module, name)
      :local -> clear_local(module, name)
    end
  end

  @doc """
  Clear all expirables for a module.
  """
  def clear_all(module) do
    ExpirableStore.Info.expirables(module)
    |> Enum.each(fn %{name: name} ->
      ExpirableStore.clear(module, name)
    end)
  end

  # ===========================================================================
  # Cluster-scoped implementation
  # ===========================================================================

  defp fetch_cluster(module, name, fetch_fn, refresh) do
    group = {module, name}
    local_pid = get_local_cluster_agent(group)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)
    else
      case Agent.get(local_pid, & &1) do
        :__error__ ->
          acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)

        {:__ready__, _, expires_at} = entry ->
          if expired?(expires_at) do
            acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)
          else
            entry
          end
      end
    end
  end

  defp acquire_lock_and_fetch_cluster(group, fetch_fn, refresh) do
    :global.trans({group, self()}, fn ->
      local_pid = get_local_cluster_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        new_pid = create_cluster_agent(group, fetch_fn, refresh)
        Agent.get(new_pid, & &1)
      else
        case Agent.get(local_pid, & &1) do
          :__error__ ->
            new_entry = to_internal(fetch_fn.())
            update_all_cluster_members(group, new_entry)
            schedule_eager_refresh_cluster(group, new_entry, fetch_fn, refresh)
            new_entry

          {:__ready__, _, expires_at} = entry ->
            if expired?(expires_at) do
              new_entry = to_internal(fetch_fn.())
              update_all_cluster_members(group, new_entry)
              schedule_eager_refresh_cluster(group, new_entry, fetch_fn, refresh)
              new_entry
            else
              entry
            end
        end
      end
    end)
  end

  defp clear_cluster(module, name) do
    group = {module, name}

    :global.trans({group, self()}, fn ->
      group
      |> get_all_cluster_agents()
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

  defp get_local_cluster_agent(group) do
    :pg.get_local_members(:expirable_store, group)
    |> List.first()
  end

  defp get_all_cluster_agents(group) do
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

  defp create_cluster_agent(group, fetch_fn, refresh) do
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

    schedule_eager_refresh_cluster(group, initial_value, fetch_fn, refresh)

    pid
  end

  defp update_all_cluster_members(group, new_entry) do
    group
    |> get_all_cluster_agents()
    |> Enum.each(fn pid ->
      try do
        Agent.update(pid, fn _ -> new_entry end)
      catch
        _, _ -> :ok
      end
    end)
  end

  # ===========================================================================
  # Local-scoped implementation (using Agent + Registry)
  # ===========================================================================

  defp fetch_local(module, name, fetch_fn, refresh) do
    key = {module, name}
    local_pid = get_local_agent(key)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      create_or_fetch_local(key, fetch_fn, refresh)
    else
      case Agent.get(local_pid, & &1) do
        :__error__ ->
          refetch_local(local_pid, key, fetch_fn, refresh)

        {:__ready__, _, expires_at} = entry ->
          if expired?(expires_at) do
            refetch_local(local_pid, key, fetch_fn, refresh)
          else
            entry
          end

        {:__refreshing__, old_entry} ->
          # Refresh in progress - return old value or wait
          handle_refreshing_state(local_pid, old_entry)

        {:__fetching__, _} ->
          # Initial fetch in progress - wait for result
          wait_for_refresh_local(local_pid)
      end
    end
  end

  defp handle_refreshing_state(_pid, {:__ready__, _, _} = old_entry), do: old_entry

  defp handle_refreshing_state(pid, :__error__) do
    wait_for_refresh_local(pid)
  end

  defp wait_for_refresh_local(pid) do
    case Agent.get(pid, & &1) do
      {:__refreshing__, _} ->
        Process.sleep(10)
        wait_for_refresh_local(pid)

      {:__fetching__, _} ->
        Process.sleep(10)
        wait_for_refresh_local(pid)

      value ->
        value
    end
  end

  # Handle race condition: create agent with fetching marker, then fetch value
  # This ensures fetch_fn is called only once even with concurrent requests
  defp create_or_fetch_local(key, fetch_fn, refresh) do
    fetching_ref = make_ref()

    spec = %{
      id: {:local, key},
      start:
        {Agent, :start_link,
         [
           fn -> {:__fetching__, fetching_ref} end,
           [name: {:via, Registry, {ExpirableStore.LocalRegistry, key}}]
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(ExpirableStore.Supervisor, spec) do
      {:ok, pid} ->
        # We won the race, fetch the value
        value = to_internal(fetch_fn.())

        Agent.update(pid, fn {:__fetching__, ^fetching_ref} -> value end)

        value
        |> tap(fn v -> schedule_eager_refresh_local(key, v, fetch_fn, refresh) end)

      {:error, {:already_started, pid}} ->
        # Another process is fetching, wait for result
        wait_for_local_value(pid)
    end
  end

  defp wait_for_local_value(pid) do
    case Agent.get(pid, & &1) do
      {:__fetching__, ref} when is_reference(ref) ->
        Process.sleep(10)
        wait_for_local_value(pid)

      value ->
        value
    end
  end

  defp refetch_local(pid, key, fetch_fn, refresh) do
    # CAS: acquire refresh lock
    case Agent.get_and_update(pid, fn
           {:__refreshing__, old_entry} ->
             # Already refreshing - return old entry
             {{:already_refreshing, old_entry}, {:__refreshing__, old_entry}}

           {:__fetching__, _} = state ->
             # Initial fetch in progress - don't interfere
             {{:fetching, state}, state}

           entry ->
             # Start refresh - set refreshing state
             {{:do_refresh, entry}, {:__refreshing__, entry}}
         end) do
      {:do_refresh, _old_entry} ->
        new_entry = to_internal(fetch_fn.())
        Agent.update(pid, fn {:__refreshing__, _} -> new_entry end)
        schedule_eager_refresh_local(key, new_entry, fetch_fn, refresh)
        new_entry

      {:already_refreshing, {:__ready__, _, _} = old_entry} ->
        # Already refreshing, return old (possibly expired) value
        old_entry

      {:already_refreshing, :__error__} ->
        # Already refreshing but no old value - wait for result
        wait_for_refresh_local(pid)

      {:fetching, _} ->
        # Initial fetch in progress - wait for result
        wait_for_refresh_local(pid)
    end
  end

  defp get_local_agent(key) do
    case Registry.lookup(ExpirableStore.LocalRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp clear_local(module, name) do
    key = {module, name}

    case get_local_agent(key) do
      nil ->
        :ok

      pid ->
        try do
          Agent.stop(pid)
        catch
          _, _ -> :ok
        end
    end

    :ok
  end

  # ===========================================================================
  # Eager refresh scheduling (cluster)
  # ===========================================================================

  defp schedule_eager_refresh_cluster(_group, :__error__, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh_cluster(_group, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh_cluster(group, {:__ready__, _value, expires_at}, fetch_fn, :eager) do
    now = System.system_time(:millisecond)
    ttl = expires_at - now

    if ttl > 0 do
      refresh_delay = trunc(ttl * 0.9)

      if refresh_delay > 0 do
        spawn(fn ->
          Process.sleep(refresh_delay)
          do_eager_refresh_cluster(group, fetch_fn)
        end)
      end
    end

    :ok
  end

  defp do_eager_refresh_cluster(group, fetch_fn) do
    :global.trans({group, self()}, fn ->
      local_pid = get_local_cluster_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        :ok
      else
        new_entry = to_internal(fetch_fn.())
        update_all_cluster_members(group, new_entry)
        schedule_eager_refresh_cluster(group, new_entry, fetch_fn, :eager)
      end
    end)
  end

  # ===========================================================================
  # Eager refresh scheduling (local)
  # ===========================================================================

  defp schedule_eager_refresh_local(_key, :__error__, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh_local(_key, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh_local(key, {:__ready__, _value, expires_at}, fetch_fn, :eager) do
    now = System.system_time(:millisecond)
    ttl = expires_at - now

    if ttl > 0 do
      refresh_delay = trunc(ttl * 0.9)

      if refresh_delay > 0 do
        spawn(fn ->
          Process.sleep(refresh_delay)
          do_eager_refresh_local(key, fetch_fn)
        end)
      end
    end

    :ok
  end

  defp do_eager_refresh_local(key, fetch_fn) do
    local_pid = get_local_agent(key)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      :ok
    else
      # CAS: acquire refresh lock
      case Agent.get_and_update(local_pid, fn
             {:__refreshing__, _} = state ->
               # Already refreshing - skip
               {:already_refreshing, state}

             {:__fetching__, _} = state ->
               # Initial fetch in progress - skip
               {:fetching, state}

             entry ->
               # Start refresh
               {:do_refresh, {:__refreshing__, entry}}
           end) do
        :do_refresh ->
          new_entry = to_internal(fetch_fn.())
          Agent.update(local_pid, fn {:__refreshing__, _} -> new_entry end)
          schedule_eager_refresh_local(key, new_entry, fetch_fn, :eager)

        :already_refreshing ->
          :ok

        :fetching ->
          :ok
      end
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp expired?(expires_at) do
    System.system_time(:millisecond) > expires_at
  end

  # Convert external format (from fetch_fn or API) to internal Agent state
  defp to_internal({:ok, value, expires_at}), do: {:__ready__, value, expires_at}
  defp to_internal(:error), do: :__error__

  # Convert internal Agent state to external format (for API return)
  defp to_external({:__ready__, value, expires_at}), do: {:ok, value, expires_at}
  defp to_external(:__error__), do: :error
end
