defmodule TestExpirables do
  @moduledoc false
  use ExpirableStore

  # ===========================================
  # scope :cluster, refresh :lazy
  # ===========================================

  expirable :cluster_lazy do
    fetch fn ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_lazy, node()})
        _ -> :ok
      end

      Process.sleep(50)
      token = "cluster_lazy_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end

    refresh :lazy
    scope :cluster
  end

  expirable :cluster_lazy_fail do
    fetch fn ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_lazy_fail, node()})
        _ -> :ok
      end

      Process.sleep(50)
      :error
    end

    refresh :lazy
    scope :cluster
  end

  # ===========================================
  # scope :cluster, refresh :eager
  # ===========================================

  expirable :cluster_eager do
    fetch fn ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :cluster_eager, node()})
        _ -> :ok
      end

      Process.sleep(50)
      token = "cluster_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end

    refresh :eager
    scope :cluster
  end

  # ===========================================
  # scope :local, refresh :lazy
  # ===========================================

  expirable :local_lazy do
    fetch fn ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :local_lazy, node()})
        _ -> :ok
      end

      Process.sleep(50)
      token = "local_lazy_#{:rand.uniform(10000)}_#{node()}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end

    refresh :lazy
    scope :local
  end

  # ===========================================
  # scope :local, refresh :eager
  # ===========================================

  expirable :local_eager do
    fetch fn ->
      case :global.whereis_name(:fetch_tracker) do
        pid when is_pid(pid) -> send(pid, {:fetch, :local_eager, node()})
        _ -> :ok
      end

      Process.sleep(50)
      token = "local_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end

    refresh :eager
    scope :local
  end
end
