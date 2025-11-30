defmodule ExpirableStore.Local do
  @moduledoc false

  # ===========================================================================
  # Public API
  # ===========================================================================

  def fetch(module, name, fetch_fn, refresh) do
    key = {module, name}
    local_pid = get_agent(key)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      create_or_fetch(key, fetch_fn, refresh)
    else
      case Agent.get(local_pid, & &1) do
        :__error__ ->
          refetch(local_pid, key, fetch_fn, refresh)

        {:__ready__, _, expires_at} = entry ->
          if expired?(expires_at) do
            refetch(local_pid, key, fetch_fn, refresh)
          else
            entry
          end

        {:__refreshing__, old_entry} ->
          # Refresh in progress - return old value or wait
          handle_refreshing_state(local_pid, old_entry)

        {:__fetching__, _} ->
          # Initial fetch in progress - wait for result
          wait_for_refresh(local_pid)
      end
    end
  end

  def clear(module, name) do
    key = {module, name}

    case get_agent(key) do
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
  # Private implementation
  # ===========================================================================

  defp handle_refreshing_state(_pid, {:__ready__, _, _} = old_entry), do: old_entry

  defp handle_refreshing_state(pid, :__error__) do
    wait_for_refresh(pid)
  end

  defp wait_for_refresh(pid) do
    case Agent.get(pid, & &1) do
      {:__refreshing__, _} ->
        Process.sleep(10)
        wait_for_refresh(pid)

      {:__fetching__, _} ->
        Process.sleep(10)
        wait_for_refresh(pid)

      value ->
        value
    end
  end

  # Handle race condition: create agent with fetching marker, then fetch value
  # This ensures fetch_fn is called only once even with concurrent requests
  defp create_or_fetch(key, fetch_fn, refresh) do
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
        |> tap(fn v -> schedule_eager_refresh(key, v, fetch_fn, refresh) end)

      {:error, {:already_started, pid}} ->
        # Another process is fetching, wait for result
        wait_for_value(pid)
    end
  end

  defp wait_for_value(pid) do
    case Agent.get(pid, & &1) do
      {:__fetching__, ref} when is_reference(ref) ->
        Process.sleep(10)
        wait_for_value(pid)

      value ->
        value
    end
  end

  defp refetch(pid, key, fetch_fn, refresh) do
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
        schedule_eager_refresh(key, new_entry, fetch_fn, refresh)
        new_entry

      {:already_refreshing, {:__ready__, _, _} = old_entry} ->
        # Already refreshing, return old (possibly expired) value
        old_entry

      {:already_refreshing, :__error__} ->
        # Already refreshing but no old value - wait for result
        wait_for_refresh(pid)

      {:fetching, _} ->
        # Initial fetch in progress - wait for result
        wait_for_refresh(pid)
    end
  end

  defp get_agent(key) do
    case Registry.lookup(ExpirableStore.LocalRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ===========================================================================
  # Eager refresh scheduling
  # ===========================================================================

  defp schedule_eager_refresh(_key, :__error__, _fetch_fn, _refresh), do: :ok
  defp schedule_eager_refresh(_key, _entry, _fetch_fn, :lazy), do: :ok

  defp schedule_eager_refresh(key, {:__ready__, _value, expires_at}, fetch_fn, :eager) do
    now = System.system_time(:millisecond)
    ttl = expires_at - now

    if ttl > 0 do
      refresh_delay = trunc(ttl * 0.9)

      if refresh_delay > 0 do
        spawn(fn ->
          Process.sleep(refresh_delay)
          do_eager_refresh(key, fetch_fn)
        end)
      end
    end

    :ok
  end

  defp do_eager_refresh(key, fetch_fn) do
    local_pid = get_agent(key)

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
          schedule_eager_refresh(key, new_entry, fetch_fn, :eager)

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

  defp to_internal({:ok, value, expires_at}), do: {:__ready__, value, expires_at}
  defp to_internal(:error), do: :__error__
end
