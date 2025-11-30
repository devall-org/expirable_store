defmodule TestExpirables do
  @moduledoc false
  use ExpirableStore

  # Cluster-scoped, lazy refresh (default)
  expirable :github do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :github, node()})
      end

      token = "gho_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end
  end

  # Always fails
  expirable :google do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :google, node()})
      end

      :error
    end
  end

  # Cluster-scoped, lazy refresh
  expirable :slack do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :slack, node()})
      end

      token = "xoxb_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + :timer.hours(1)
      {:ok, token, expires_at}
    end
  end

  # Local-scoped, lazy refresh
  expirable :local_token do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :local_token, node()})
      end

      token = "local_#{:rand.uniform(10000)}_#{node()}"
      expires_at = System.system_time(:millisecond) + 200
      {:ok, token, expires_at}
    end

    scope :local
  end

  # Cluster-scoped, eager refresh
  expirable :eager_token do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :eager_token, node()})
      end

      token = "eager_#{:rand.uniform(10000)}"
      # Short TTL for testing eager refresh (100ms, so eager refresh at 90ms)
      expires_at = System.system_time(:millisecond) + 100
      {:ok, token, expires_at}
    end

    refresh :eager
    scope :cluster
  end

  # Local-scoped, eager refresh
  expirable :local_eager_token do
    fetch fn ->
      if pid = Process.whereis(:fetch_tracker) do
        send(pid, {:fetch, :local_eager_token, node()})
      end

      token = "local_eager_#{:rand.uniform(10000)}"
      expires_at = System.system_time(:millisecond) + 100
      {:ok, token, expires_at}
    end

    refresh :eager
    scope :local
  end
end
