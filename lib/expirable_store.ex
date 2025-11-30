defmodule ExpirableStore do
  @moduledoc """
  A lightweight expirable value store for Elixir.

  Provides compile-time DSL for defining expirable values with configurable
  refresh strategies and scoping (cluster-wide or local).
  """

  use Spark.Dsl, default_extensions: [extensions: [ExpirableStore.Dsl]]

  @doc """
  Fetch a cached value, returning `{:ok, value, expires_at}` on success or `:error` on failure.

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
  Fetch a cached value, raising an exception on failure.

  Returns the cached value directly without expiration time.
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

    case get_local_agent(group) do
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
      case get_local_agent(group) do
        nil ->
          local_pid = create_cluster_agent(group, fetch_fn, refresh)
          Agent.get(local_pid, & &1)

        local_pid ->
          if Process.alive?(local_pid) do
            case Agent.get(local_pid, & &1) do
              :error ->
                new_entry = fetch_fn.()
                update_all_members(group, new_entry)
                schedule_eager_refresh(group, new_entry, fetch_fn, refresh)
                new_entry

              {:ok, _, expires_at} = entry ->
                if expired?(expires_at) do
                  new_entry = fetch_fn.()
                  update_all_members(group, new_entry)
                  schedule_eager_refresh(group, new_entry, fetch_fn, refresh)
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
      |> get_all_agents()
      |> Enum.each(fn pid ->
        try do
          Agent.stop(pid)
        catch
          _, _ -> :ok
        end
      end)
    end)
  end

  defp get_local_agent(group) do
    :pg.get_local_members(:expirable_store, group)
    |> List.first()
  end

  defp get_all_agents(group) do
    :pg.get_members(:expirable_store, group)
  end

  defp create_cluster_agent(group, fetch_fn, refresh) do
    initial_value =
      case :pg.get_members(:expirable_store, group) do
        [remote_pid | _] ->
          Agent.get(remote_pid, & &1)

        [] ->
          fetch_fn.()
      end

    spec = %{
      id: group,
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
      Agent.update(pid, fn _ -> new_entry end)
    end)
  end

  # ===========================================================================
  # Local-scoped implementation
  # ===========================================================================

  defp fetch_local(module, name, fetch_fn, refresh) do
    key = {module, name}

    case :ets.lookup(:expirable_store_local, key) do
      [] ->
        do_fetch_local(key, fetch_fn, refresh)

      [{^key, :error}] ->
        do_fetch_local(key, fetch_fn, refresh)

      [{^key, {:ok, _value, expires_at} = entry}] ->
        if expired?(expires_at) do
          do_fetch_local(key, fetch_fn, refresh)
        else
          entry
        end
    end
  end

  defp do_fetch_local(key, fetch_fn, refresh) do
    entry = fetch_fn.()
    :ets.insert(:expirable_store_local, {key, entry})
    schedule_eager_refresh_local(key, entry, fetch_fn, refresh)
    entry
  end

  defp clear_local(module, name) do
    key = {module, name}
    :ets.delete(:expirable_store_local, key)
    :ok
  end

  # ===========================================================================
  # Eager refresh scheduling
  # ===========================================================================

  defp schedule_eager_refresh(_group, :error, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh(_group, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh(group, {:ok, _value, expires_at}, fetch_fn, :eager) do
    now = System.system_time(:millisecond)
    ttl = expires_at - now

    if ttl > 0 do
      # Schedule refresh at 90% of TTL (i.e., 10% before expiry)
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
      case get_local_agent(group) do
        nil ->
          :ok

        local_pid ->
          if Process.alive?(local_pid) do
            new_entry = fetch_fn.()
            update_all_members(group, new_entry)
            schedule_eager_refresh(group, new_entry, fetch_fn, :eager)
          end
      end
    end)
  end

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
    new_entry = fetch_fn.()
    :ets.insert(:expirable_store_local, {key, new_entry})
    schedule_eager_refresh_local(key, new_entry, fetch_fn, :eager)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp expired?(expires_at) do
    System.system_time(:millisecond) > expires_at
  end
end
