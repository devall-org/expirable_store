defmodule ExpirableStore.Local do
  @moduledoc false

  # ===========================================================================
  # Public API
  # ===========================================================================

  def fetch(module, name, fetch_fn, refresh) do
    key = {module, name}
    local_pid = get_agent(key)

    if is_nil(local_pid) or not Process.alive?(local_pid) do
      acquire_lock_and_fetch(key, fetch_fn, refresh)
    else
      case Agent.get(local_pid, & &1) do
        :__error__ ->
          acquire_lock_and_fetch(key, fetch_fn, refresh)

        {:__ready__, _, expires_at} = entry ->
          if expired?(expires_at) do
            acquire_lock_and_fetch(key, fetch_fn, refresh)
          else
            entry
          end
      end
    end
  end

  def clear(module, name) do
    key = {module, name}

    :global.trans(
      {key, self()},
      fn ->
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
      end,
      [node()]
    )

    :ok
  end

  # ===========================================================================
  # Private implementation
  # ===========================================================================

  defp acquire_lock_and_fetch(key, fetch_fn, refresh) do
    :global.trans(
      {key, self()},
      fn ->
        local_pid = get_agent(key)

        if is_nil(local_pid) or not Process.alive?(local_pid) do
          new_pid = create_agent(key, fetch_fn, refresh)
          Agent.get(new_pid, & &1)
        else
          case Agent.get(local_pid, & &1) do
            :__error__ ->
              new_entry = to_internal(fetch_fn.())
              Agent.update(local_pid, fn _ -> new_entry end)
              schedule_eager_refresh(key, new_entry, fetch_fn, refresh)
              new_entry

            {:__ready__, _, expires_at} = entry ->
              if expired?(expires_at) do
                new_entry = to_internal(fetch_fn.())
                Agent.update(local_pid, fn _ -> new_entry end)
                schedule_eager_refresh(key, new_entry, fetch_fn, refresh)
                new_entry
              else
                entry
              end
          end
        end
      end,
      [node()]
    )
  end

  defp get_agent(key) do
    case Registry.lookup(ExpirableStore.LocalRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp create_agent(key, fetch_fn, refresh) do
    initial_value = to_internal(fetch_fn.())

    spec = %{
      id: {:local, key},
      start:
        {Agent, :start_link,
         [
           fn -> initial_value end,
           [name: {:via, Registry, {ExpirableStore.LocalRegistry, key}}]
         ]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(ExpirableStore.Supervisor, spec)

    schedule_eager_refresh(key, initial_value, fetch_fn, refresh)

    pid
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
    :global.trans(
      {key, self()},
      fn ->
        local_pid = get_agent(key)

        if is_nil(local_pid) or not Process.alive?(local_pid) do
          :ok
        else
          new_entry = to_internal(fetch_fn.())
          Agent.update(local_pid, fn _ -> new_entry end)
          schedule_eager_refresh(key, new_entry, fetch_fn, :eager)
        end
      end,
      [node()]
    )
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
