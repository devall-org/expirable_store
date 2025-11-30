defmodule ExpirableStore.LocalTest do
  use ExUnit.Case, async: false
  doctest ExpirableStore

  setup do
    Process.register(self(), :fetch_tracker)

    on_exit(fn ->
      TestExpirables.clear_all()

      if Process.whereis(:fetch_tracker) do
        Process.unregister(:fetch_tracker)
      end

      Process.sleep(10)
    end)

    :ok
  end

  # ===========================================================================
  # scope :cluster, refresh :lazy
  # ===========================================================================

  describe "scope :cluster, refresh :lazy" do
    test "caches tokens until expiration" do
      now = System.system_time(:millisecond)
      {:ok, token1, expires_at1} = TestExpirables.fetch(:github)
      assert_receive {:fetch, :github, _}
      assert is_integer(expires_at1)
      assert expires_at1 > now

      {:ok, token2, expires_at2} = TestExpirables.fetch(:github)
      refute_receive {:fetch, :github, _}
      assert token1 == token2
      assert expires_at1 == expires_at2

      Process.sleep(300)

      {:ok, token3, expires_at3} = TestExpirables.fetch(:github)
      assert_receive {:fetch, :github, _}
      assert token3 != token1
      assert expires_at3 > expires_at1
    end

    test "does not cache fetch failures" do
      :error = TestExpirables.fetch(:google)
      assert_receive {:fetch, :google, _}

      :error = TestExpirables.fetch(:google)
      assert_receive {:fetch, :google, _}
    end

    test "agents are added to :pg groups" do
      group = {TestExpirables, :github}
      assert :pg.get_members(:expirable_store, group) == []

      {:ok, _, _} = TestExpirables.fetch(:github)
      assert length(:pg.get_members(:expirable_store, group)) == 1

      TestExpirables.clear(:github)
      assert :pg.get_members(:expirable_store, group) == []
    end

    test "clear removes cache before expiration" do
      {:ok, token1, _} = TestExpirables.fetch(:github)
      {:ok, token2, _} = TestExpirables.fetch(:github)
      assert token1 == token2

      TestExpirables.clear(:github)

      {:ok, token3, _} = TestExpirables.fetch(:github)
      assert token3 != token1
    end
  end

  # ===========================================================================
  # scope :cluster, refresh :eager
  # ===========================================================================

  describe "scope :cluster, refresh :eager" do
    test "refreshes automatically before expiry" do
      {:ok, token1, _} = TestExpirables.fetch(:eager_token)
      assert_receive {:fetch, :eager_token, _}

      # Wait for eager refresh (should happen at ~90ms, before 100ms expiry)
      Process.sleep(120)

      # Eager refresh should have happened in background
      assert_receive {:fetch, :eager_token, _}, 50

      # Value should still be valid (refreshed)
      {:ok, token2, _} = TestExpirables.fetch(:eager_token)
      assert token2 != token1
    end

    test "agents are added to :pg groups" do
      group = {TestExpirables, :eager_token}
      assert :pg.get_members(:expirable_store, group) == []

      {:ok, _, _} = TestExpirables.fetch(:eager_token)
      assert length(:pg.get_members(:expirable_store, group)) == 1
    end

    test "clear stops eager refresh" do
      {:ok, token1, _} = TestExpirables.fetch(:eager_token)
      assert_receive {:fetch, :eager_token, _}

      TestExpirables.clear(:eager_token)

      {:ok, token2, _} = TestExpirables.fetch(:eager_token)
      assert_receive {:fetch, :eager_token, _}
      assert token2 != token1
    end
  end

  # ===========================================================================
  # scope :local, refresh :lazy
  # ===========================================================================

  describe "scope :local, refresh :lazy" do
    test "caches tokens locally until expiration" do
      {:ok, token1, expires_at1} = TestExpirables.fetch(:local_token)
      assert_receive {:fetch, :local_token, _}

      {:ok, token2, expires_at2} = TestExpirables.fetch(:local_token)
      refute_receive {:fetch, :local_token, _}
      assert token1 == token2
      assert expires_at1 == expires_at2

      Process.sleep(300)

      {:ok, token3, _} = TestExpirables.fetch(:local_token)
      assert_receive {:fetch, :local_token, _}
      assert token3 != token1
    end

    test "does not use pg groups" do
      {:ok, _, _} = TestExpirables.fetch(:local_token)
      assert :pg.get_members(:expirable_store, {TestExpirables, :local_token}) == []
    end

    test "uses Registry instead" do
      {:ok, _, _} = TestExpirables.fetch(:local_token)

      assert [{_pid, _}] =
               Registry.lookup(ExpirableStore.LocalRegistry, {TestExpirables, :local_token})
    end

    test "clear removes cache" do
      {:ok, token1, _} = TestExpirables.fetch(:local_token)
      TestExpirables.clear(:local_token)
      {:ok, token2, _} = TestExpirables.fetch(:local_token)
      assert token2 != token1
    end
  end

  # ===========================================================================
  # scope :local, refresh :eager
  # ===========================================================================

  describe "scope :local, refresh :eager" do
    test "refreshes automatically before expiry" do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager_token)
      assert_receive {:fetch, :local_eager_token, _}

      Process.sleep(120)

      assert_receive {:fetch, :local_eager_token, _}, 50

      {:ok, token2, _} = TestExpirables.fetch(:local_eager_token)
      assert token2 != token1
    end

    test "does not use pg groups" do
      {:ok, _, _} = TestExpirables.fetch(:local_eager_token)
      assert :pg.get_members(:expirable_store, {TestExpirables, :local_eager_token}) == []
    end

    test "clear stops eager refresh" do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager_token)
      assert_receive {:fetch, :local_eager_token, _}

      TestExpirables.clear(:local_eager_token)

      {:ok, token2, _} = TestExpirables.fetch(:local_eager_token)
      assert_receive {:fetch, :local_eager_token, _}
      assert token2 != token1
    end
  end

  # ===========================================================================
  # Common functionality
  # ===========================================================================

  describe "fetch!/1" do
    test "returns token on success (cluster)" do
      token = TestExpirables.fetch!(:github)
      assert_receive {:fetch, :github, _}
      assert String.starts_with?(token, "gho_")
    end

    test "returns token on success (local)" do
      token = TestExpirables.fetch!(:local_token)
      assert_receive {:fetch, :local_token, _}
      assert String.starts_with?(token, "local_")
    end

    test "raises on fetch failure" do
      assert_raise RuntimeError, fn -> TestExpirables.fetch!(:google) end
      assert_receive {:fetch, :google, _}
    end
  end

  describe "named functions" do
    test "github() returns same as fetch(:github)" do
      {:ok, token1, exp1} = TestExpirables.github()
      assert_receive {:fetch, :github, _}

      {:ok, token2, exp2} = TestExpirables.fetch(:github)
      refute_receive {:fetch, :github, _}

      assert token1 == token2
      assert exp1 == exp2
    end

    test "github!() returns same as fetch!(:github)" do
      token = TestExpirables.github!()
      assert_receive {:fetch, :github, _}
      assert String.starts_with?(token, "gho_")
    end

    test "google!() raises on failure" do
      assert_raise RuntimeError, fn -> TestExpirables.google!() end
    end

    test "local_token() works for local scope" do
      {:ok, token, _} = TestExpirables.local_token()
      assert_receive {:fetch, :local_token, _}
      assert String.starts_with?(token, "local_")
    end
  end

  describe "clear_all/0" do
    test "removes all caches" do
      {:ok, token1, _} = TestExpirables.fetch(:github)
      {:ok, local1, _} = TestExpirables.fetch(:local_token)
      :error = TestExpirables.fetch(:google)

      TestExpirables.clear_all()

      {:ok, token2, _} = TestExpirables.fetch(:github)
      {:ok, local2, _} = TestExpirables.fetch(:local_token)
      assert token2 != token1
      assert local2 != local1
    end
  end

  describe "supervision" do
    test "agents are added to DynamicSupervisor" do
      %{active: active_before} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)

      {:ok, _, _} = TestExpirables.fetch(:github)
      %{active: active_after_1} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_1 == active_before + 1

      {:ok, _, _} = TestExpirables.fetch(:local_token)
      %{active: active_after_2} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_2 == active_before + 2

      TestExpirables.clear(:github)
      %{active: active_after_clear} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_clear == active_before + 1
    end
  end
end
