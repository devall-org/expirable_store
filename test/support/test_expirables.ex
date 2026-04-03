defmodule TestExpirables do
  @moduledoc false
  use ExpirableStore

  # ===========================================
  # scope :cluster, refresh :lazy
  # ===========================================

  expirable :cluster_lazy do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_lazy, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "cluster_lazy_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    refresh :lazy
    scope :cluster
  end

  expirable :cluster_lazy_fail do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_lazy_fail, node()})
        _ -> :ok
      end

      Process.sleep(100)
      {:error, nil}
    end

    refresh :lazy
    scope :cluster
  end

  # ===========================================
  # scope :cluster, refresh :eager
  # ===========================================

  expirable :cluster_eager do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_eager, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "cluster_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    refresh {:eager, before_expiry: 40}
    scope :cluster
  end

  # ===========================================
  # scope :local, refresh :lazy
  # ===========================================

  expirable :local_lazy do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :local_lazy, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "local_lazy_#{:rand.uniform(10000)}_#{node()}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    refresh :lazy
    scope :local
  end

  # ===========================================
  # scope :local, refresh :eager
  # ===========================================

  expirable :local_eager do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :local_eager, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "local_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    refresh {:eager, before_expiry: 40}
    scope :local
  end

  # ===========================================
  # expires_at :infinity (never expires)
  # ===========================================

  expirable :never_expires do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :never_expires, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "never_expires_#{:rand.uniform(10000)}"
      {:ok, token, :infinity, nil}
    end

    refresh :lazy
    scope :cluster
  end

  expirable :never_expires_eager do
    fetch fn _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :never_expires_eager, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "never_expires_eager_#{:rand.uniform(10000)}"
      {:ok, token, :infinity, nil}
    end

    refresh {:eager, before_expiry: 40}
    scope :cluster
  end

  # ===========================================
  # keyed, scope :cluster, refresh :lazy
  # ===========================================

  expirable :cluster_lazy_keyed do
    fetch fn key, _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_lazy_keyed, key, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "cluster_lazy_keyed_#{key}_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    keyed true
    refresh :lazy
    scope :cluster
  end

  # ===========================================
  # keyed, scope :cluster, refresh :eager
  # ===========================================

  expirable :cluster_eager_keyed do
    fetch fn key, _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_eager_keyed, key, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "cluster_eager_keyed_#{key}_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    keyed true
    refresh {:eager, before_expiry: 40}
    scope :cluster
  end

  # ===========================================
  # keyed, scope :local, refresh :lazy
  # ===========================================

  expirable :local_lazy_keyed do
    fetch fn key, _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :local_lazy_keyed, key, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "local_lazy_keyed_#{key}_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    keyed true
    refresh :lazy
    scope :local
  end

  # ===========================================
  # keyed, scope :local, refresh :eager
  # ===========================================

  expirable :local_eager_keyed do
    fetch fn key, _state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :local_eager_keyed, key, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "local_eager_keyed_#{key}_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, nil}
    end

    keyed true
    refresh {:eager, before_expiry: 40}
    scope :local
  end

  # ===========================================
  # stateful (counter between fetches)
  # ===========================================

  expirable :stateful_counter do
    fetch fn state ->
      count = (state || 0) + 1

      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :stateful_counter, count, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "stateful_counter_#{count}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, count}
    end

    refresh :lazy
    scope :cluster
  end

  # ===========================================
  # require_init (non-keyed)
  # ===========================================

  expirable :require_init_example do
    fetch fn state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :require_init_example, state, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "require_init_#{state[:token_prefix]}_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, state}
    end

    require_initial_state true
    refresh :lazy
    scope :cluster
  end

  # ===========================================
  # require_init (keyed)
  # ===========================================

  expirable :require_init_keyed do
    fetch fn key, state ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :require_init_keyed, key, state, node()})
        _ -> :ok
      end

      Process.sleep(100)
      token = "require_init_keyed_#{key}_#{state[:token_prefix]}_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 400
      {:ok, token, expires_at, state}
    end

    keyed true
    require_initial_state true
    refresh :lazy
    scope :cluster
  end
end
