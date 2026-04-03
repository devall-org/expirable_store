defmodule ExpirableStore.Store do
  @moduledoc false

  # Agent state: {cached_result, user_state}
  # cached_result: {:ok, value, expires_at} | :error | :not_fetched
  # user_state: any term (nil when require_initial_state is false)

  # ===========================================================================
  # Public API
  # ===========================================================================

  def set_state(module, name, state, scope) do
    group = make_group(scope, module, name)
    do_set_state(group, state, scope)
  end

  def set_state(module, name, key, state, scope) do
    group = make_group(scope, module, name, key)
    do_set_state(group, state, scope)
  end

  def fetch(module, name, fetch_fn, refresh, scope, require_init) do
    group = make_group(scope, module, name)
    do_fetch(group, fetch_fn, refresh, scope, require_init)
  end

  def fetch(module, name, key, fetch_fn, refresh, scope, require_init) do
    group = make_group(scope, module, name, key)
    do_fetch(group, fetch_fn, refresh, scope, require_init)
  end

  def clear(module, name, scope) do
    group = make_group(scope, module, name)
    do_clear(group, scope)
  end

  def clear(module, name, key, scope) do
    group = make_group(scope, module, name, key)
    do_clear(group, scope)
  end

  def clear_keyed_family(module, name, scope) do
    family_group = make_family_group(scope, module, name)

    global_trans(family_group, scope, fn ->
      family_group
      |> get_all_agents()
      |> Enum.each(fn pid ->
        try do
          Agent.stop(pid)
        catch
          _, _ -> :ok
        end
      end)
    end)

    wait_for_pg_cleanup(family_group)
  end

  # ===========================================================================
  # Private implementation
  # ===========================================================================

  defp make_group(:cluster, module, name), do: {:cluster, :unkeyed, module, name}
  defp make_group(:local, module, name), do: {:local, node(), :unkeyed, module, name}

  defp make_group(:cluster, module, name, key), do: {:cluster, :keyed, module, name, key}
  defp make_group(:local, module, name, key), do: {:local, node(), :keyed, module, name, key}

  defp make_family_group(:cluster, module, name), do: {:cluster, :keyed_family, module, name}
  defp make_family_group(:local, module, name), do: {:local, node(), :keyed_family, module, name}

  defp family_group_from({:cluster, :keyed, module, name, _key}),
    do: {:cluster, :keyed_family, module, name}

  defp family_group_from({:local, _node, :keyed, module, name, _key}),
    do: {:local, node(), :keyed_family, module, name}

  defp family_group_from({:cluster, :unkeyed, _, _}), do: nil
  defp family_group_from({:local, _, :unkeyed, _, _}), do: nil

  defp global_trans(group, :cluster, fun) do
    :global.trans({group, self()}, fun)
  end

  defp global_trans(group, :local, fun) do
    :global.trans({group, self()}, fun, [node()])
  end

  defp do_set_state(group, init_state, scope) do
    global_trans(group, scope, fn ->
      local_pid = get_local_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        start_agent(group, {:not_fetched, init_state}, scope)
        :ok
      else
        Agent.update(local_pid, fn {cached_result, _old_state} -> {cached_result, init_state} end)
        :ok
      end
    end)
  end

  defp do_fetch(group, fetch_fn, refresh, scope, require_init) do
    local_pid = get_local_agent(group)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      if require_init do
        {:error, :state_required}
      else
        acquire_lock_and_fetch(group, fetch_fn, refresh, scope, nil)
      end
    else
      {cached_result, state} = Agent.get(local_pid, & &1)

      case cached_result do
        :not_fetched ->
          acquire_lock_and_fetch(group, fetch_fn, refresh, scope, state)

        :error ->
          acquire_lock_and_fetch(group, fetch_fn, refresh, scope, state)

        {:ok, _, expires_at} ->
          if expired?(expires_at) do
            acquire_lock_and_fetch(group, fetch_fn, refresh, scope, state)
          else
            cached_result
          end
      end
    end
  end

  defp do_clear(group, scope) do
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

  defp get_local_agent(group) do
    :pg.get_local_members(:expirable_store, group)
    |> List.first()
  end

  defp get_all_agents(group) do
    :pg.get_members(:expirable_store, group)
  end

  defp get_agent_state_from_cluster(group) do
    :pg.get_members(:expirable_store, group)
    |> Enum.find_value(fn pid ->
      try do
        Agent.get(pid, & &1)
      catch
        :exit, _ -> nil
      end
    end)
  end

  defp start_agent(group, agent_state, scope) do
    spec = %{
      id: {scope, group},
      start: {Agent, :start_link, [fn -> agent_state end]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(ExpirableStore.Supervisor, spec)
    :ok = :pg.join(:expirable_store, group, pid)

    case family_group_from(group) do
      nil -> :ok
      family_group -> :ok = :pg.join(:expirable_store, family_group, pid)
    end

    pid
  end

  defp acquire_lock_and_fetch(group, fetch_fn, refresh, scope, state) do
    global_trans(group, scope, fn ->
      local_pid = get_local_agent(group)

      if is_nil(local_pid) or not Process.alive?(local_pid) do
        case get_agent_state_from_cluster(group) do
          {cached_result, cluster_state}
          when cached_result != :error and cached_result != :not_fetched ->
            start_agent(group, {cached_result, cluster_state}, scope)
            cached_result

          {_cached_result, cluster_state} ->
            fetch_and_create_agent(group, fetch_fn, refresh, scope, cluster_state)

          nil ->
            fetch_and_create_agent(group, fetch_fn, refresh, scope, state)
        end
      else
        {cached_result, current_state} = Agent.get(local_pid, & &1)

        case cached_result do
          x when x in [:not_fetched, :error] ->
            fetch_and_update(group, fetch_fn, refresh, scope, current_state)

          {:ok, _, expires_at} ->
            if expired?(expires_at) do
              fetch_and_update(group, fetch_fn, refresh, scope, current_state)
            else
              cached_result
            end
        end
      end
    end)
  end

  defp fetch_and_create_agent(group, fetch_fn, refresh, scope, state) do
    {cached_result, next_state} = call_fetch(fetch_fn, state)
    start_agent(group, {cached_result, next_state}, scope)
    schedule_eager_refresh(group, cached_result, fetch_fn, refresh, scope)
    cached_result
  end

  defp fetch_and_update(group, fetch_fn, refresh, scope, state) do
    {cached_result, next_state} = call_fetch(fetch_fn, state)
    update_all_members(group, {cached_result, next_state})
    schedule_eager_refresh(group, cached_result, fetch_fn, refresh, scope)
    cached_result
  end

  defp call_fetch(fetch_fn, state) do
    case fetch_fn.(state) do
      {:ok, value, expires_at, next_state} -> {{:ok, value, expires_at}, next_state}
      {:error, next_state} -> {:error, next_state}
    end
  end

  defp update_all_members(group, agent_state) do
    group
    |> get_all_agents()
    |> Enum.each(fn pid ->
      try do
        Agent.update(pid, fn _ -> agent_state end)
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
        {_cached_result, state} = Agent.get(local_pid, & &1)
        {new_cached_result, next_state} = call_fetch(fetch_fn, state)
        update_all_members(group, {new_cached_result, next_state})
        schedule_eager_refresh(group, new_cached_result, fetch_fn, refresh, scope)
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
