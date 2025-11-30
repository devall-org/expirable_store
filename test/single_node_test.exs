defmodule ExpirableStore.SingleNodeTest do
  use ExUnit.Case, async: false
  doctest ExpirableStore

  setup do
    :yes = :global.register_name(:fetch_tracker, self())

    on_exit(fn ->
      TestExpirables.clear_all()
      :global.unregister_name(:fetch_tracker)
      Process.sleep(10)
    end)

    :ok
  end

  # ===========================================================================
  # scope :cluster, refresh :lazy
  # ===========================================================================

  describe "scope :cluster, refresh :lazy" do
    test "stores tokens until expiration" do
      now = System.system_time(:millisecond)
      {:ok, token1, expires_at1} = TestExpirables.fetch(:cluster_lazy)
      assert_receive {:fetch, :cluster_lazy, _}
      assert is_integer(expires_at1)
      assert expires_at1 > now

      {:ok, token2, expires_at2} = TestExpirables.fetch(:cluster_lazy)
      refute_receive {:fetch, :cluster_lazy, _}
      assert token1 == token2
      assert expires_at1 == expires_at2

      Process.sleep(300)

      {:ok, token3, expires_at3} = TestExpirables.fetch(:cluster_lazy)
      assert_receive {:fetch, :cluster_lazy, _}
      assert token3 != token1
      assert expires_at3 > expires_at1
    end

    test "does not store fetch failures" do
      :error = TestExpirables.fetch(:cluster_lazy_fail)
      assert_receive {:fetch, :cluster_lazy_fail, _}

      :error = TestExpirables.fetch(:cluster_lazy_fail)
      assert_receive {:fetch, :cluster_lazy_fail, _}
    end

    test "agents are added to :pg groups" do
      group = {TestExpirables, :cluster_lazy}
      assert length(:pg.get_members(:expirable_store, group)) == 0

      {:ok, _, _} = TestExpirables.fetch(:cluster_lazy)
      assert length(:pg.get_members(:expirable_store, group)) == 1

      TestExpirables.clear(:cluster_lazy)
      assert length(:pg.get_members(:expirable_store, group)) == 0
    end

    test "clear removes value before expiration" do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_lazy)
      {:ok, token2, _} = TestExpirables.fetch(:cluster_lazy)
      assert token1 == token2

      TestExpirables.clear(:cluster_lazy)

      {:ok, token3, _} = TestExpirables.fetch(:cluster_lazy)
      assert token3 != token1
    end
  end

  # ===========================================================================
  # scope :cluster, refresh :eager
  # ===========================================================================

  describe "scope :cluster, refresh :eager" do
    test "refreshes automatically before expiry" do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_eager)
      assert_receive {:fetch, :cluster_eager, _}

      # Wait for eager refresh (should happen at ~90ms, before 100ms expiry)
      Process.sleep(120)

      # Eager refresh should have happened in background
      assert_receive {:fetch, :cluster_eager, _}, 50

      # Value should still be valid (refreshed)
      {:ok, token2, _} = TestExpirables.fetch(:cluster_eager)
      assert token2 != token1
    end

    test "agents are added to :pg groups" do
      group = {TestExpirables, :cluster_eager}
      assert length(:pg.get_members(:expirable_store, group)) == 0

      {:ok, _, _} = TestExpirables.fetch(:cluster_eager)
      assert length(:pg.get_members(:expirable_store, group)) == 1
    end

    test "clear stops eager refresh" do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_eager)
      assert_receive {:fetch, :cluster_eager, _}

      TestExpirables.clear(:cluster_eager)

      {:ok, token2, _} = TestExpirables.fetch(:cluster_eager)
      assert_receive {:fetch, :cluster_eager, _}
      assert token2 != token1
    end
  end

  # ===========================================================================
  # scope :local, refresh :lazy
  # ===========================================================================

  describe "scope :local, refresh :lazy" do
    test "stores tokens locally until expiration" do
      {:ok, token1, expires_at1} = TestExpirables.fetch(:local_lazy)
      assert_receive {:fetch, :local_lazy, _}

      {:ok, token2, expires_at2} = TestExpirables.fetch(:local_lazy)
      refute_receive {:fetch, :local_lazy, _}
      assert token1 == token2
      assert expires_at1 == expires_at2

      Process.sleep(300)

      {:ok, token3, _} = TestExpirables.fetch(:local_lazy)
      assert_receive {:fetch, :local_lazy, _}
      assert token3 != token1
    end

    test "does not use pg groups" do
      {:ok, _, _} = TestExpirables.fetch(:local_lazy)
      assert length(:pg.get_members(:expirable_store, {TestExpirables, :local_lazy})) == 0
    end

    test "uses Registry instead" do
      {:ok, _, _} = TestExpirables.fetch(:local_lazy)

      assert [{_pid, _}] =
               Registry.lookup(ExpirableStore.LocalRegistry, {TestExpirables, :local_lazy})
    end

    test "clear removes value" do
      {:ok, token1, _} = TestExpirables.fetch(:local_lazy)
      TestExpirables.clear(:local_lazy)
      {:ok, token2, _} = TestExpirables.fetch(:local_lazy)
      assert token2 != token1
    end
  end

  # ===========================================================================
  # scope :local, refresh :eager
  # ===========================================================================

  describe "scope :local, refresh :eager" do
    test "refreshes automatically before expiry" do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager)
      assert_receive {:fetch, :local_eager, _}

      Process.sleep(120)

      assert_receive {:fetch, :local_eager, _}, 50

      {:ok, token2, _} = TestExpirables.fetch(:local_eager)
      assert token2 != token1
    end

    test "does not use pg groups" do
      {:ok, _, _} = TestExpirables.fetch(:local_eager)
      assert length(:pg.get_members(:expirable_store, {TestExpirables, :local_eager})) == 0
    end

    test "clear stops eager refresh" do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager)
      assert_receive {:fetch, :local_eager, _}

      TestExpirables.clear(:local_eager)

      {:ok, token2, _} = TestExpirables.fetch(:local_eager)
      assert_receive {:fetch, :local_eager, _}
      assert token2 != token1
    end
  end

  # ===========================================================================
  # Common functionality
  # ===========================================================================

  describe "fetch!/1" do
    test "returns token on success (cluster)" do
      token = TestExpirables.fetch!(:cluster_lazy)
      assert_receive {:fetch, :cluster_lazy, _}
      assert String.starts_with?(token, "cluster_lazy_")
    end

    test "returns token on success (local)" do
      token = TestExpirables.fetch!(:local_lazy)
      assert_receive {:fetch, :local_lazy, _}
      assert String.starts_with?(token, "local_lazy_")
    end

    test "raises on fetch failure" do
      assert_raise RuntimeError, fn -> TestExpirables.fetch!(:cluster_lazy_fail) end
      assert_receive {:fetch, :cluster_lazy_fail, _}
    end
  end

  describe "named functions" do
    test "cluster_lazy() returns same as fetch(:cluster_lazy)" do
      {:ok, token1, exp1} = TestExpirables.cluster_lazy()
      assert_receive {:fetch, :cluster_lazy, _}

      {:ok, token2, exp2} = TestExpirables.fetch(:cluster_lazy)
      refute_receive {:fetch, :cluster_lazy, _}

      assert token1 == token2
      assert exp1 == exp2
    end

    test "cluster_lazy!() returns same as fetch!(:cluster_lazy)" do
      token = TestExpirables.cluster_lazy!()
      assert_receive {:fetch, :cluster_lazy, _}
      assert String.starts_with?(token, "cluster_lazy_")
    end

    test "cluster_lazy_fail!() raises on failure" do
      assert_raise RuntimeError, fn -> TestExpirables.cluster_lazy_fail!() end
    end

    test "local_lazy() works for local scope" do
      {:ok, token, _} = TestExpirables.local_lazy()
      assert_receive {:fetch, :local_lazy, _}
      assert String.starts_with?(token, "local_lazy_")
    end
  end

  describe "clear_all/0" do
    test "removes all values" do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_lazy)
      {:ok, local1, _} = TestExpirables.fetch(:local_lazy)
      :error = TestExpirables.fetch(:cluster_lazy_fail)

      TestExpirables.clear_all()

      {:ok, token2, _} = TestExpirables.fetch(:cluster_lazy)
      {:ok, local2, _} = TestExpirables.fetch(:local_lazy)
      assert token2 != token1
      assert local2 != local1
    end
  end

  describe "supervision" do
    test "agents are added to DynamicSupervisor" do
      %{active: active_before} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)

      {:ok, _, _} = TestExpirables.fetch(:cluster_lazy)
      %{active: active_after_1} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_1 == active_before + 1

      {:ok, _, _} = TestExpirables.fetch(:local_lazy)
      %{active: active_after_2} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_2 == active_before + 2

      TestExpirables.clear(:cluster_lazy)
      %{active: active_after_clear} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_clear == active_before + 1
    end
  end
end
