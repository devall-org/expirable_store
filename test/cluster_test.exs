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

  # ===========================================================================
  # scope :cluster, refresh :lazy (multi-node)
  # ===========================================================================

  describe "scope :cluster, refresh :lazy (multi-node)" do
    test "value is replicated across nodes", %{node2: node2} do
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

    test "each node has local replica via :pg", %{node2: node2} do
      group = {TestExpirables, :github}

      assert :pg.get_local_members(:expirable_store, group) == []
      assert :erpc.call(node2, :pg, :get_local_members, [:expirable_store, group]) == []

      {:ok, _, _} = TestExpirables.fetch(:github)

      assert length(:pg.get_local_members(:expirable_store, group)) == 1
      assert :erpc.call(node2, :pg, :get_local_members, [:expirable_store, group]) == []

      :erpc.call(node2, TestExpirables, :fetch, [:github])

      assert length(:pg.get_members(:expirable_store, group)) == 2
      assert length(:pg.get_local_members(:expirable_store, group)) == 1
      assert length(:erpc.call(node2, :pg, :get_local_members, [:expirable_store, group])) == 1
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

  # ===========================================================================
  # scope :cluster, refresh :eager (multi-node)
  # ===========================================================================

  describe "scope :cluster, refresh :eager (multi-node)" do
    test "value is replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:eager_token)
      {:ok, token2, _} = :erpc.call(node2, TestExpirables, :fetch, [:eager_token])
      assert token1 == token2
    end

    test "eager refresh updates all replicas", %{node2: node2} do
      Process.register(self(), :fetch_tracker)

      {:ok, token1, _} = TestExpirables.fetch(:eager_token)
      assert_receive {:fetch, :eager_token, _}

      # Create replica on node2
      {:ok, _, _} = :erpc.call(node2, TestExpirables, :fetch, [:eager_token])

      # Wait for eager refresh
      Process.sleep(120)
      assert_receive {:fetch, :eager_token, _}, 50

      # Both nodes should have the new token
      {:ok, token2, _} = TestExpirables.fetch(:eager_token)
      {:ok, token3, _} = :erpc.call(node2, TestExpirables, :fetch, [:eager_token])
      assert token2 != token1
      assert token2 == token3

      Process.unregister(:fetch_tracker)
    end
  end

  # ===========================================================================
  # scope :local, refresh :lazy (multi-node)
  # ===========================================================================

  describe "scope :local, refresh :lazy (multi-node)" do
    test "is NOT replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:local_token)
      {:ok, token2, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])

      assert token1 != token2
      assert String.contains?(token1, to_string(node()))
      assert String.contains?(token2, to_string(node2))
    end

    test "stores independently per node", %{node2: node2} do
      {:ok, token1a, _} = TestExpirables.fetch(:local_token)
      {:ok, token1b, _} = TestExpirables.fetch(:local_token)
      assert token1a == token1b

      {:ok, token2a, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])
      assert token2a != token1a

      {:ok, token2b, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])
      assert token2a == token2b
    end

    test "does not use :pg groups", %{node2: node2} do
      {:ok, _, _} = TestExpirables.fetch(:local_token)
      {:ok, _, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_token])

      assert :pg.get_members(:expirable_store, {TestExpirables, :local_token}) == []
    end
  end

  # ===========================================================================
  # scope :local, refresh :eager (multi-node)
  # ===========================================================================

  describe "scope :local, refresh :eager (multi-node)" do
    test "is NOT replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager_token)
      {:ok, token2, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_eager_token])

      assert token1 != token2
    end

    test "eager refresh works independently per node", %{node2: node2} do
      Process.register(self(), :fetch_tracker)

      {:ok, token1, _} = TestExpirables.fetch(:local_eager_token)
      assert_receive {:fetch, :local_eager_token, _}

      # Wait for eager refresh on node1
      Process.sleep(120)
      assert_receive {:fetch, :local_eager_token, _}, 50

      {:ok, token2, _} = TestExpirables.fetch(:local_eager_token)
      assert token2 != token1

      # node2 should still get its own independent token
      {:ok, token3, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_eager_token])
      assert token3 != token2

      Process.unregister(:fetch_tracker)
    end
  end
end
