defmodule ExpirableStore.MultiNodeTest do
  use ExUnit.Case, async: false

  @moduletag :multi_node

  setup do
    [{_pid2, node2}] = nodes = ClusterHelper.start_nodes([:node2])
    :yes = :global.register_name(:fetch_tracker, self())
    :ok = :global.sync()

    on_exit(fn ->
      TestExpirables.clear_all()
      :global.unregister_name(:fetch_tracker)
      ClusterHelper.stop_nodes(nodes)
    end)

    {:ok, node2: node2}
  end

  # ===========================================================================
  # scope :cluster, refresh :lazy (multi-node)
  # ===========================================================================

  describe "scope :cluster, refresh :lazy (multi-node)" do
    test "value is replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = :erpc.call(node2, TestExpirables, :fetch, [:cluster_lazy])
      {:ok, token2, _} = TestExpirables.fetch(:cluster_lazy)
      assert token1 == token2
    end

    test "updates are synchronized across nodes", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_lazy)
      Process.sleep(105)

      {:ok, token2, _} = TestExpirables.fetch(:cluster_lazy)
      assert token2 != token1

      {:ok, token3, _} = :erpc.call(node2, TestExpirables, :fetch, [:cluster_lazy])
      assert token3 == token2
    end

    test "does not store fetch failures", %{node2: node2} do
      :error = TestExpirables.fetch(:cluster_lazy_fail)
      assert_receive {:fetch, :cluster_lazy_fail, _}

      :error = :erpc.call(node2, TestExpirables, :fetch, [:cluster_lazy_fail])
      assert_receive {:fetch, :cluster_lazy_fail, _}
    end

    test "each node has local replica via :pg", %{node2: node2} do
      group = {TestExpirables, :cluster_lazy}

      assert length(:pg.get_local_members(:expirable_store, group)) == 0
      assert length(:erpc.call(node2, :pg, :get_local_members, [:expirable_store, group])) == 0

      {:ok, _, _} = TestExpirables.fetch(:cluster_lazy)

      assert length(:pg.get_local_members(:expirable_store, group)) == 1
      assert length(:erpc.call(node2, :pg, :get_local_members, [:expirable_store, group])) == 0

      :erpc.call(node2, TestExpirables, :fetch, [:cluster_lazy])

      assert length(:pg.get_members(:expirable_store, group)) == 2
      assert length(:pg.get_local_members(:expirable_store, group)) == 1
      assert length(:erpc.call(node2, :pg, :get_local_members, [:expirable_store, group])) == 1
    end

    test "concurrent updates are safe", %{node2: node2} do
      {:ok, _, _} = TestExpirables.fetch(:cluster_lazy)
      assert_receive {:fetch, :cluster_lazy, _}
      Process.sleep(105)

      task1 = Task.async(fn -> :erpc.call(node2, TestExpirables, :fetch, [:cluster_lazy]) end)
      task2 = Task.async(fn -> TestExpirables.fetch(:cluster_lazy) end)

      {:ok, token1, _} = Task.await(task1)
      {:ok, token2, _} = Task.await(task2)

      assert token1 == token2

      # Only one fetch should have been called (from either node)
      assert_receive {:fetch, :cluster_lazy, _}
      refute_receive {:fetch, :cluster_lazy, _}
    end
  end

  # ===========================================================================
  # scope :cluster, refresh :eager (multi-node)
  # ===========================================================================

  describe "scope :cluster, refresh :eager (multi-node)" do
    test "value is replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = :erpc.call(node2, TestExpirables, :fetch, [:cluster_eager])
      {:ok, token2, _} = TestExpirables.fetch(:cluster_eager)
      assert token1 == token2
    end

    test "eager refresh updates all replicas", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_eager)
      assert_receive {:fetch, :cluster_eager, _}

      # Create replica on node2
      {:ok, _, _} = :erpc.call(node2, TestExpirables, :fetch, [:cluster_eager])

      # Wait for eager refresh (should happen at ~90ms)
      Process.sleep(95)
      assert_receive {:fetch, :cluster_eager, _}
      # Both nodes should have the new token
      {:ok, token2, _} = TestExpirables.fetch(:cluster_eager)
      {:ok, token3, _} = :erpc.call(node2, TestExpirables, :fetch, [:cluster_eager])
      assert token2 != token1
      assert token2 == token3
    end
  end

  # ===========================================================================
  # scope :local, refresh :lazy (multi-node)
  # ===========================================================================

  describe "scope :local, refresh :lazy (multi-node)" do
    test "is NOT replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_lazy])
      {:ok, token2, _} = TestExpirables.fetch(:local_lazy)

      assert token1 != token2
      assert String.contains?(token1, to_string(node2))
      assert String.contains?(token2, to_string(node()))
    end

    test "stores independently per node", %{node2: node2} do
      {:ok, token1a, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_lazy])
      {:ok, token1b, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_lazy])
      assert token1a == token1b

      {:ok, token2a, _} = TestExpirables.fetch(:local_lazy)
      assert token2a != token1a

      {:ok, token2b, _} = TestExpirables.fetch(:local_lazy)
      assert token2a == token2b
    end

    test "does not use :pg groups", %{node2: node2} do
      {:ok, _, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_lazy])
      {:ok, _, _} = TestExpirables.fetch(:local_lazy)

      assert length(:pg.get_members(:expirable_store, {TestExpirables, :local_lazy})) == 0
    end
  end

  # ===========================================================================
  # scope :local, refresh :eager (multi-node)
  # ===========================================================================

  describe "scope :local, refresh :eager (multi-node)" do
    test "is NOT replicated across nodes", %{node2: node2} do
      {:ok, token1, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_eager])
      {:ok, token2, _} = TestExpirables.fetch(:local_eager)

      assert token1 != token2
    end

    test "eager refresh works independently per node", %{node2: node2} do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager)
      assert_receive {:fetch, :local_eager, _}

      # Wait for eager refresh on node1 (should happen at ~90ms)
      Process.sleep(95)
      assert_receive {:fetch, :local_eager, _}
      {:ok, token2, _} = TestExpirables.fetch(:local_eager)
      assert token2 != token1

      # node2 should still get its own independent token
      {:ok, token3, _} = :erpc.call(node2, TestExpirables, :fetch, [:local_eager])
      assert token3 != token2
    end
  end
end
