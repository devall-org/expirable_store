defmodule ExpirableStore.ClusterTest do
  use ExUnit.Case, async: false

  @moduletag :cluster

  setup do
    nodes = ClusterHelper.start_nodes([:node2])
    [{_pid2, node2}] = nodes

    on_exit(fn ->
      TestExpirables.clear_all()
      ClusterHelper.stop_nodes(nodes)
    end)

    {:ok, node2: node2}
  end

  describe "scope :cluster (multi-node)" do
    test "cache is replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:github)
      {:ok, token2, _} = :erpc.call(node2, TestExpirables, :fetch, [:github])
      assert token1 == token2
    end

    test "updates are synchronized across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:github)
      Process.sleep(250)

      {:ok, token2, _} = TestExpirables.fetch(:github)
      assert token2 != token1

      {:ok, token3, _} = :erpc.call(node2, TestExpirables, :fetch, [:github])
      assert token3 == token2
    end

    test "each node has local replica", %{node2: node2} do
      group = {TestExpirables, :github}

      assert :pg.get_local_members(:expirable_store, group) == []
      local2_before = :erpc.call(node2, :pg, :get_local_members, [:expirable_store, group])
      assert local2_before == []

      {:ok, _, _} = TestExpirables.fetch(:github)

      assert length(:pg.get_local_members(:expirable_store, group)) == 1
      assert :erpc.call(node2, :pg, :get_local_members, [:expirable_store, group]) == []

      :erpc.call(node2, TestExpirables, :fetch, [:github])

      assert length(:pg.get_members(:expirable_store, group)) == 2

      assert length(:pg.get_local_members(:expirable_store, group)) == 1
      local2_after = :erpc.call(node2, :pg, :get_local_members, [:expirable_store, group])
      assert length(local2_after) == 1
    end

    test "concurrent updates are safe", %{node2: node2} do
      Process.register(self(), :fetch_tracker)

      {:ok, _, _} = TestExpirables.fetch(:github)
      assert_receive {:fetch, :github, _}, 100

      Process.sleep(250)

      task1 = Task.async(fn -> TestExpirables.fetch(:github) end)
      task2 = Task.async(fn -> :erpc.call(node2, TestExpirables, :fetch, [:github]) end)

      {:ok, token1, _} = Task.await(task1)
      {:ok, token2, _} = Task.await(task2)

      assert token1 == token2

      assert_receive {:fetch, :github, _}, 100
      refute_receive {:fetch, :github, _}, 100

      Process.unregister(:fetch_tracker)
    end
  end

  describe "scope :local (multi-node)" do
    test "local scope is NOT replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:local_token)
      {:ok, token2, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])

      # Tokens should be different (each node fetches independently)
      assert token1 != token2

      # Tokens should contain node name
      assert String.contains?(token1, to_string(node()))
      assert String.contains?(token2, to_string(node2))
    end

    test "local scope caches independently per node", %{node2: node2} do
      {:ok, token1a, _} = TestExpirables.fetch(:local_token)

      # Second fetch on same node uses cache
      {:ok, token1b, _} = TestExpirables.fetch(:local_token)
      assert token1a == token1b

      # Fetch on node2 creates new independent cache
      {:ok, token2a, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])
      assert token2a != token1a

      # Second fetch on node2 uses its cache
      {:ok, token2b, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])
      assert token2a == token2b
    end
  end
end
