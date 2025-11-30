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

    case scope do
      :cluster -> fetch_cluster(module, name, fetch_fn, refresh)
      :local -> fetch_local(module, name, fetch_fn, refresh)
    end
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

    case get_cluster_agent(group) do
      nil ->
        acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)

      local_pid ->
        if Process.alive?(local_pid) do
          case Agent.get(local_pid, & &1) do
            :error ->
              acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)

            {:ok, _, expires_at} = entry ->
              if expired?(expires_at) do
                acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)
              else
                entry
              end
          end
        else
          acquire_lock_and_fetch_cluster(group, fetch_fn, refresh)
        end
    end
  end

  defp acquire_lock_and_fetch_cluster(group, fetch_fn, refresh) do
    :global.trans(group, fn ->
      case get_cluster_agent(group) do
        nil ->
          local_pid = create_cluster_agent(group, fetch_fn, refresh)
          Agent.get(local_pid, & &1)

        local_pid ->
          if Process.alive?(local_pid) do
            case Agent.get(local_pid, & &1) do
              :error ->
                new_entry = fetch_fn.()
                update_all_cluster_members(group, new_entry)
                schedule_eager_refresh_cluster(group, new_entry, fetch_fn, refresh)
                new_entry

              {:ok, _, expires_at} = entry ->
                if expired?(expires_at) do
                  new_entry = fetch_fn.()
                  update_all_cluster_members(group, new_entry)
                  schedule_eager_refresh_cluster(group, new_entry, fetch_fn, refresh)
                  new_entry
                else
                  entry
                end
            end
          else
            new_pid = create_cluster_agent(group, fetch_fn, refresh)
            Agent.get(new_pid, & &1)
          end
      end
    end)
  end

  defp clear_cluster(module, name) do
    group = {module, name}

    :global.trans(group, fn ->
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

  defp get_cluster_agent(group) do
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
        :exit, _ -> :error
      end
    end)
  end

  defp create_cluster_agent(group, fetch_fn, refresh) do
    initial_value =
      case get_value_from_cluster(group) do
        {:ok, _, _} = entry -> entry
        _ -> fetch_fn.()
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

    case get_local_agent(key) do
      nil ->
        create_or_fetch_local(key, fetch_fn, refresh)

      local_pid ->
        if Process.alive?(local_pid) do
          case Agent.get(local_pid, & &1) do
            :error ->
              refetch_local(local_pid, key, fetch_fn, refresh)

            {:ok, _, expires_at} = entry ->
              if expired?(expires_at) do
                refetch_local(local_pid, key, fetch_fn, refresh)
              else
                entry
              end
          end
        else
          create_or_fetch_local(key, fetch_fn, refresh)
        end
    end
  end

  # Handle race condition: create agent with pending marker, then fetch value
  # This ensures fetch_fn is called only once even with concurrent requests
  defp create_or_fetch_local(key, fetch_fn, refresh) do
    pending_ref = make_ref()

    spec = %{
      id: {:local, key},
      start:
        {Agent, :start_link,
         [
           fn -> {:__pending__, pending_ref} end,
           [name: {:via, Registry, {ExpirableStore.LocalRegistry, key}}]
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(ExpirableStore.Supervisor, spec) do
      {:ok, pid} ->
        # We won the race, fetch the value
        value = fetch_fn.()

        Agent.update(pid, fn {:__pending__, ^pending_ref} -> value end)

        value
        |> tap(fn v -> schedule_eager_refresh_local(key, v, fetch_fn, refresh) end)

      {:error, {:already_started, pid}} ->
        # Another process is fetching, wait for result
        wait_for_local_value(pid)
    end
  end

  defp wait_for_local_value(pid) do
    case Agent.get(pid, & &1) do
      {:__pending__, ref} when is_reference(ref) ->
        Process.sleep(10)
        wait_for_local_value(pid)

      value ->
        value
    end
  end

  defp refetch_local(pid, key, fetch_fn, refresh) do
    new_entry = fetch_fn.()
    Agent.update(pid, fn _ -> new_entry end)
    schedule_eager_refresh_local(key, new_entry, fetch_fn, refresh)
    new_entry
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

  defp schedule_eager_refresh_cluster(_group, :error, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh_cluster(_group, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh_cluster(group, {:ok, _value, expires_at}, fetch_fn, :eager) do
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
    :global.trans(group, fn ->
      case get_cluster_agent(group) do
        nil ->
          :ok

        local_pid ->
          if Process.alive?(local_pid) do
            new_entry = fetch_fn.()
            update_all_cluster_members(group, new_entry)
            schedule_eager_refresh_cluster(group, new_entry, fetch_fn, :eager)
          end
      end
    end)
  end

  # ===========================================================================
  # Eager refresh scheduling (local)
  # ===========================================================================

  defp schedule_eager_refresh_local(_key, :error, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh_local(_key, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh_local(key, {:ok, _value, expires_at}, fetch_fn, :eager) do
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
    case get_local_agent(key) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          new_entry = fetch_fn.()
          Agent.update(pid, fn _ -> new_entry end)
          schedule_eager_refresh_local(key, new_entry, fetch_fn, :eager)
        end
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp expired?(expires_at) do
    System.system_time(:millisecond) > expires_at
  end
end
