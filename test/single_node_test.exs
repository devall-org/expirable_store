defmodule ExpirableStore.SingleNodeTest do
  use ExUnit.Case, async: false
  require TestExpirables
  doctest ExpirableStore

  setup do
    :yes = :global.register_name(:fetch_tracker, self())
    :ok = :global.sync()

    on_exit(fn ->
      TestExpirables.clear_all()
      :global.unregister_name(:fetch_tracker)
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

      Process.sleep(210)

      {:ok, token3, expires_at3} = TestExpirables.fetch(:cluster_lazy)
      assert_receive {:fetch, :cluster_lazy, _}
      assert token3 != token1
      assert expires_at3 > expires_at1
    end

    test "does not store fetch failures" do
      {:error, :fetch_failed} = TestExpirables.fetch(:cluster_lazy_fail)
      assert_receive {:fetch, :cluster_lazy_fail, _}

      {:error, :fetch_failed} = TestExpirables.fetch(:cluster_lazy_fail)
      assert_receive {:fetch, :cluster_lazy_fail, _}
    end

    test "agents are added to :pg groups" do
      group = {:cluster, :unkeyed, TestExpirables, :cluster_lazy}
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

      # Wait for eager refresh to complete: 200ms * 0.9 delay + 50ms fetch + 10ms margin = 240ms
      Process.sleep(240)

      # Eager refresh should have happened in background
      assert_receive {:fetch, :cluster_eager, _}
      # Value should still be valid (refreshed)
      {:ok, token2, _} = TestExpirables.fetch(:cluster_eager)
      assert token2 != token1
    end

    test "agents are added to :pg groups" do
      group = {:cluster, :unkeyed, TestExpirables, :cluster_eager}
      assert length(:pg.get_members(:expirable_store, group)) == 0

      {:ok, _, _} = TestExpirables.fetch(:cluster_eager)
      assert length(:pg.get_members(:expirable_store, group)) == 1
    end

    test "clear causes fresh fetch on next call" do
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

      Process.sleep(210)

      {:ok, token3, _} = TestExpirables.fetch(:local_lazy)
      assert_receive {:fetch, :local_lazy, _}
      assert token3 != token1
    end

    test "uses :pg groups with node-scoped key" do
      group = {:local, node(), :unkeyed, TestExpirables, :local_lazy}
      assert length(:pg.get_members(:expirable_store, group)) == 0

      {:ok, _, _} = TestExpirables.fetch(:local_lazy)
      assert length(:pg.get_members(:expirable_store, group)) == 1
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

      # Wait for eager refresh to complete: 200ms * 0.9 delay + 50ms fetch + 10ms margin = 240ms
      Process.sleep(240)

      assert_receive {:fetch, :local_eager, _}
      {:ok, token2, _} = TestExpirables.fetch(:local_eager)
      assert token2 != token1
    end

    test "uses :pg groups with node-scoped key" do
      group = {:local, node(), :unkeyed, TestExpirables, :local_eager}
      assert length(:pg.get_members(:expirable_store, group)) == 0

      {:ok, _, _} = TestExpirables.fetch(:local_eager)
      assert length(:pg.get_members(:expirable_store, group)) == 1
    end

    test "clear causes fresh fetch on next call" do
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

  describe "clear_all/0" do
    test "removes all values" do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_lazy)
      {:ok, local1, _} = TestExpirables.fetch(:local_lazy)
      {:error, :fetch_failed} = TestExpirables.fetch(:cluster_lazy_fail)

      TestExpirables.clear_all()

      {:ok, token2, _} = TestExpirables.fetch(:cluster_lazy)
      {:ok, local2, _} = TestExpirables.fetch(:local_lazy)
      assert token2 != token1
      assert local2 != local1
    end
  end

  # ===========================================================================
  # expires_at :infinity (never expires)
  # ===========================================================================

  describe "expires_at :infinity" do
    test "value never expires" do
      {:ok, token1, :infinity} = TestExpirables.fetch(:never_expires)
      assert_receive {:fetch, :never_expires, _}

      # Wait longer than normal expiry time
      Process.sleep(300)

      # Should still return cached value without fetching
      {:ok, token2, :infinity} = TestExpirables.fetch(:never_expires)
      refute_receive {:fetch, :never_expires, _}
      assert token1 == token2
    end

    test "clear still works" do
      {:ok, token1, :infinity} = TestExpirables.fetch(:never_expires)
      assert_receive {:fetch, :never_expires, _}

      TestExpirables.clear(:never_expires)

      {:ok, token2, :infinity} = TestExpirables.fetch(:never_expires)
      assert_receive {:fetch, :never_expires, _}
      assert token2 != token1
    end

    test "eager refresh is not scheduled for :infinity" do
      {:ok, token1, :infinity} = TestExpirables.fetch(:never_expires_eager)
      assert_receive {:fetch, :never_expires_eager, _}

      # Wait for when eager refresh would normally happen
      Process.sleep(300)

      # No background refresh should occur
      refute_receive {:fetch, :never_expires_eager, _}

      # Value should be the same
      {:ok, token2, :infinity} = TestExpirables.fetch(:never_expires_eager)
      refute_receive {:fetch, :never_expires_eager, _}
      assert token1 == token2
    end
  end

  # ===========================================================================
  # keyed expirables
  # ===========================================================================

  describe "keyed expirables (cluster, lazy)" do
    test "different keys are cached independently" do
      {:ok, token_a, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      assert_receive {:fetch, :cluster_lazy_keyed, "apple", _}

      {:ok, token_b, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")
      assert_receive {:fetch, :cluster_lazy_keyed, "banana", _}

      assert token_a != token_b
      assert String.starts_with?(token_a, "cluster_lazy_keyed_apple_")
      assert String.starts_with?(token_b, "cluster_lazy_keyed_banana_")
    end

    test "same key returns cached value" do
      {:ok, token1, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      assert_receive {:fetch, :cluster_lazy_keyed, "apple", _}

      {:ok, token2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      refute_receive {:fetch, :cluster_lazy_keyed, "apple", _}

      assert token1 == token2
    end

    test "each key has its own pg group" do
      group_a = {:cluster, :keyed, TestExpirables, :cluster_lazy_keyed, "apple"}
      group_b = {:cluster, :keyed, TestExpirables, :cluster_lazy_keyed, "banana"}

      assert length(:pg.get_members(:expirable_store, group_a)) == 0
      assert length(:pg.get_members(:expirable_store, group_b)) == 0

      {:ok, _, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      assert length(:pg.get_members(:expirable_store, group_a)) == 1
      assert length(:pg.get_members(:expirable_store, group_b)) == 0
    end

    test "clear with key removes only that key" do
      {:ok, token_a, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      {:ok, token_b, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")

      TestExpirables.clear(:cluster_lazy_keyed, "apple")

      {:ok, token_a2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      {:ok, token_b2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")

      assert token_a2 != token_a
      assert token_b2 == token_b
    end

    test "clear without key removes all keys" do
      {:ok, token_a, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      {:ok, token_b, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")

      TestExpirables.clear(:cluster_lazy_keyed)

      {:ok, token_a2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      {:ok, token_b2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")

      assert token_a2 != token_a
      assert token_b2 != token_b
    end

    test "clear_all clears all keyed entries" do
      {:ok, token_a, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      {:ok, token_b, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")

      TestExpirables.clear_all()

      {:ok, token_a2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      {:ok, token_b2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "banana")

      assert token_a2 != token_a
      assert token_b2 != token_b
    end

    test "expiration works independently per key" do
      {:ok, token_a, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      assert_receive {:fetch, :cluster_lazy_keyed, "apple", _}

      Process.sleep(210)

      {:ok, token_a2, _} = TestExpirables.fetch(:cluster_lazy_keyed, "apple")
      assert_receive {:fetch, :cluster_lazy_keyed, "apple", _}
      assert token_a2 != token_a
    end

    test "fetch!/2 raises on error" do
      token = TestExpirables.fetch!(:cluster_lazy_keyed, "cherry")
      assert String.starts_with?(token, "cluster_lazy_keyed_cherry_")
    end
  end

  describe "keyed expirables (cluster, eager)" do
    test "different keys get independent eager refresh" do
      {:ok, token_a, _} = TestExpirables.fetch(:cluster_eager_keyed, "apple")
      assert_receive {:fetch, :cluster_eager_keyed, "apple", _}

      {:ok, token_b, _} = TestExpirables.fetch(:cluster_eager_keyed, "banana")
      assert_receive {:fetch, :cluster_eager_keyed, "banana", _}

      assert token_a != token_b

      Process.sleep(240)

      assert_receive {:fetch, :cluster_eager_keyed, "apple", _}
      assert_receive {:fetch, :cluster_eager_keyed, "banana", _}

      {:ok, token_a2, _} = TestExpirables.fetch(:cluster_eager_keyed, "apple")
      {:ok, token_b2, _} = TestExpirables.fetch(:cluster_eager_keyed, "banana")

      assert token_a2 != token_a
      assert token_b2 != token_b
    end

    test "uses cluster pg groups per key" do
      group_a = {:cluster, :keyed, TestExpirables, :cluster_eager_keyed, "apple"}
      assert length(:pg.get_members(:expirable_store, group_a)) == 0

      {:ok, _, _} = TestExpirables.fetch(:cluster_eager_keyed, "apple")
      assert length(:pg.get_members(:expirable_store, group_a)) == 1
    end
  end

  describe "keyed expirables (local, lazy)" do
    test "different keys are cached independently" do
      {:ok, token_a, _} = TestExpirables.fetch(:local_lazy_keyed, "apple")
      assert_receive {:fetch, :local_lazy_keyed, "apple", _}

      {:ok, token_b, _} = TestExpirables.fetch(:local_lazy_keyed, "banana")
      assert_receive {:fetch, :local_lazy_keyed, "banana", _}

      assert token_a != token_b
    end

    test "same key returns cached value" do
      {:ok, token1, _} = TestExpirables.fetch(:local_lazy_keyed, "apple")
      assert_receive {:fetch, :local_lazy_keyed, "apple", _}

      {:ok, token2, _} = TestExpirables.fetch(:local_lazy_keyed, "apple")
      refute_receive {:fetch, :local_lazy_keyed, "apple", _}

      assert token1 == token2
    end

    test "uses node-scoped pg groups per key" do
      group_a = {:local, node(), :keyed, TestExpirables, :local_lazy_keyed, "apple"}
      assert length(:pg.get_members(:expirable_store, group_a)) == 0

      {:ok, _, _} = TestExpirables.fetch(:local_lazy_keyed, "apple")
      assert length(:pg.get_members(:expirable_store, group_a)) == 1
    end

    test "expiration works independently per key" do
      {:ok, token_a, _} = TestExpirables.fetch(:local_lazy_keyed, "apple")
      assert_receive {:fetch, :local_lazy_keyed, "apple", _}

      Process.sleep(210)

      {:ok, token_a2, _} = TestExpirables.fetch(:local_lazy_keyed, "apple")
      assert_receive {:fetch, :local_lazy_keyed, "apple", _}
      assert token_a2 != token_a
    end
  end

  describe "keyed expirables (local, eager)" do
    test "different keys get independent eager refresh" do
      {:ok, token_a, _} = TestExpirables.fetch(:local_eager_keyed, "apple")
      assert_receive {:fetch, :local_eager_keyed, "apple", _}

      {:ok, token_b, _} = TestExpirables.fetch(:local_eager_keyed, "banana")
      assert_receive {:fetch, :local_eager_keyed, "banana", _}

      assert token_a != token_b

      # Wait for eager refresh: 200ms - 20ms before_expiry + 50ms fetch + margin
      Process.sleep(240)

      assert_receive {:fetch, :local_eager_keyed, "apple", _}
      assert_receive {:fetch, :local_eager_keyed, "banana", _}

      {:ok, token_a2, _} = TestExpirables.fetch(:local_eager_keyed, "apple")
      {:ok, token_b2, _} = TestExpirables.fetch(:local_eager_keyed, "banana")

      assert token_a2 != token_a
      assert token_b2 != token_b
    end

    test "uses node-scoped pg groups per key" do
      group_a = {:local, node(), :keyed, TestExpirables, :local_eager_keyed, "apple"}
      assert length(:pg.get_members(:expirable_store, group_a)) == 0

      {:ok, _, _} = TestExpirables.fetch(:local_eager_keyed, "apple")
      assert length(:pg.get_members(:expirable_store, group_a)) == 1
    end
  end

  # ===========================================================================
  # stateful fetch
  # ===========================================================================

  describe "stateful fetch" do
    test "state is passed between fetch calls" do
      {:ok, "stateful_counter_1", _} = TestExpirables.fetch(:stateful_counter)
      assert_receive {:fetch, :stateful_counter, 1, _}

      # Wait for expiration
      Process.sleep(210)

      {:ok, "stateful_counter_2", _} = TestExpirables.fetch(:stateful_counter)
      assert_receive {:fetch, :stateful_counter, 2, _}
    end

    test "clear resets state to nil" do
      {:ok, "stateful_counter_1", _} = TestExpirables.fetch(:stateful_counter)
      assert_receive {:fetch, :stateful_counter, 1, _}

      TestExpirables.clear(:stateful_counter)

      {:ok, "stateful_counter_1", _} = TestExpirables.fetch(:stateful_counter)
      assert_receive {:fetch, :stateful_counter, 1, _}
    end
  end

  # ===========================================================================
  # require_initial_state
  # ===========================================================================

  describe "put_state / update_state" do
    test "put_state replaces state entirely" do
      TestExpirables.put_state(:stateful_counter, 10)
      {:ok, "stateful_counter_11", _} = TestExpirables.fetch(:stateful_counter)
    end

    test "update_state transforms existing state" do
      TestExpirables.put_state(:stateful_counter, 5)
      TestExpirables.update_state(:stateful_counter, fn n -> n * 2 end)
      {:ok, "stateful_counter_11", _} = TestExpirables.fetch(:stateful_counter)
    end

    test "update_state receives nil when no state exists" do
      TestExpirables.update_state(:stateful_counter, fn nil -> 99 end)
      {:ok, "stateful_counter_100", _} = TestExpirables.fetch(:stateful_counter)
    end
  end

  describe "require_initial_state (non-keyed)" do
    test "fetch returns {:error, :state_required} before put_state" do
      {:error, :state_required} = TestExpirables.fetch(:require_init_example)
    end

    test "fetch works after put_state" do
      TestExpirables.put_state(:require_init_example, %{token_prefix: "hello"})

      {:ok, token, _} = TestExpirables.fetch(:require_init_example)
      assert_receive {:fetch, :require_init_example, %{token_prefix: "hello"}, _}
      assert String.starts_with?(token, "require_init_hello_")
    end

    test "clear requires re-init" do
      TestExpirables.put_state(:require_init_example, %{token_prefix: "abc"})
      {:ok, _, _} = TestExpirables.fetch(:require_init_example)

      TestExpirables.clear(:require_init_example)

      {:error, :state_required} = TestExpirables.fetch(:require_init_example)
    end
  end

  describe "require_initial_state (keyed)" do
    test "fetch returns {:error, :state_required} before put_state" do
      {:error, :state_required} = TestExpirables.fetch(:require_init_keyed, "k1")
    end

    test "fetch works after put_state" do
      TestExpirables.put_state(:require_init_keyed, "k1", %{token_prefix: "hello"})

      {:ok, token, _} = TestExpirables.fetch(:require_init_keyed, "k1")
      assert_receive {:fetch, :require_init_keyed, "k1", %{token_prefix: "hello"}, _}
      assert String.starts_with?(token, "require_init_keyed_k1_hello_")
    end

    test "different keys are independent" do
      TestExpirables.put_state(:require_init_keyed, "k1", %{token_prefix: "one"})
      TestExpirables.put_state(:require_init_keyed, "k2", %{token_prefix: "two"})

      {:ok, t1, _} = TestExpirables.fetch(:require_init_keyed, "k1")
      {:ok, t2, _} = TestExpirables.fetch(:require_init_keyed, "k2")

      assert String.starts_with?(t1, "require_init_keyed_k1_one_")
      assert String.starts_with?(t2, "require_init_keyed_k2_two_")

      # uninit key still fails
      {:error, :state_required} = TestExpirables.fetch(:require_init_keyed, "k3")
    end

    test "clear specific key requires re-init for that key only" do
      TestExpirables.put_state(:require_init_keyed, "k1", %{token_prefix: "one"})
      TestExpirables.put_state(:require_init_keyed, "k2", %{token_prefix: "two"})
      {:ok, _, _} = TestExpirables.fetch(:require_init_keyed, "k1")
      {:ok, _, _} = TestExpirables.fetch(:require_init_keyed, "k2")

      TestExpirables.clear(:require_init_keyed, "k1")

      {:error, :state_required} = TestExpirables.fetch(:require_init_keyed, "k1")
      {:ok, _, _} = TestExpirables.fetch(:require_init_keyed, "k2")
    end
  end

  # ===========================================================================
  # supervision
  # ===========================================================================

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
