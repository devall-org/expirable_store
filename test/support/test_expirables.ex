defmodule TestExpirables do
  @moduledoc false
  use ExpirableStore

  # ===========================================
  # scope :cluster, refresh :lazy
  # ===========================================

  expirable :cluster_lazy do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :cluster_lazy, node()})
      end

      token = "cluster_lazy_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end

    refresh :lazy
    scope :cluster
  end

  expirable :cluster_lazy_fail do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :cluster_lazy_fail, node()})
      end

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
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :cluster_eager, node()})
      end

      token = "cluster_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 100
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
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :local_lazy, node()})
      end

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
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :local_eager, node()})
      end

      token = "local_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 100
      {:ok, token, expires_at}
    end

    refresh :eager
    scope :local
  end
end
