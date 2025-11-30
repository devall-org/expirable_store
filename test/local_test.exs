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

      # Ensure :pg groups are cleaned
      Process.sleep(10)
    end)

    :ok
  end

  describe "fetch/1 with scope :cluster (default)" do
    test "caches tokens until expiration" do
      now = System.system_time(:millisecond)
      {:ok, token1, expires_at1} = TestExpirables.fetch(:github)
      assert_receive {:fetch, :github, _}
      assert is_integer(expires_at1)
      assert expires_at1 > now

      {:ok, token2, expires_at2} = TestExpirables.fetch(:github)
      # cached, no re-execution (no external API call)
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
      # failures are retried on each call
      assert_receive {:fetch, :google, _}
    end
  end

  describe "fetch/1 with scope :local" do
    test "caches tokens locally until expiration" do
      {:ok, token1, expires_at1} = TestExpirables.fetch(:local_token)
      assert_receive {:fetch, :local_token, _}

      {:ok, token2, expires_at2} = TestExpirables.fetch(:local_token)
      refute_receive {:fetch, :local_token, _}
      assert token1 == token2
      assert expires_at1 == expires_at2

      Process.sleep(300)

      {:ok, token3, _expires_at3} = TestExpirables.fetch(:local_token)
      assert_receive {:fetch, :local_token, _}
      assert token3 != token1
    end

    test "local scope does not use pg groups" do
      {:ok, _token, _} = TestExpirables.fetch(:local_token)

      # Local-scoped expirables don't join pg groups
      assert :pg.get_members(:expirable_store, {TestExpirables, :local_token}) == []
    end
  end

  describe "fetch/1 with refresh :eager" do
    test "refreshes automatically before expiry" do
      {:ok, token1, _} = TestExpirables.fetch(:eager_token)
      assert_receive {:fetch, :eager_token, _}

      # Wait for eager refresh (should happen at ~90ms, before 100ms expiry)
      Process.sleep(120)

      # Eager refresh should have happened in background
      assert_receive {:fetch, :eager_token, _}, 50

      # Value should still be valid (refreshed) - not expired, no sync fetch needed
      {:ok, token2, _} = TestExpirables.fetch(:eager_token)
      assert token2 != token1
      # Note: eager refresh may have scheduled another refresh, so we just verify
      # the token was updated without a synchronous fetch (value changed in background)
    end

    test "local eager refresh works" do
      {:ok, token1, _} = TestExpirables.fetch(:local_eager_token)
      assert_receive {:fetch, :local_eager_token, _}

      Process.sleep(120)

      assert_receive {:fetch, :local_eager_token, _}, 50

      {:ok, token2, _} = TestExpirables.fetch(:local_eager_token)
      assert token2 != token1
    end
  end

  describe "fetch!/1" do
    test "returns token on success" do
      token = TestExpirables.fetch!(:github)
      assert_receive {:fetch, :github, _}
      assert String.starts_with?(token, "gho_")
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
  end

  describe "clear" do
    test "removes cache before expiration" do
      {:ok, token1, _} = TestExpirables.fetch(:github)
      {:ok, token2, _} = TestExpirables.fetch(:github)
      assert token1 == token2

      TestExpirables.clear(:github)

      {:ok, token3, _} = TestExpirables.fetch(:github)
      assert token3 != token1
    end

    test "clear works for local scope" do
      {:ok, token1, _} = TestExpirables.fetch(:local_token)
      TestExpirables.clear(:local_token)
      {:ok, token2, _} = TestExpirables.fetch(:local_token)
      assert token2 != token1
    end

    test "clear_all removes all caches" do
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

  describe "supervision (cluster scope)" do
    test "agents are added to DynamicSupervisor" do
      %{active: active_before} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)

      {:ok, _, _} = TestExpirables.fetch(:github)
      %{active: active_after_1} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_1 == active_before + 1

      {:ok, _, _} = TestExpirables.fetch(:slack)
      %{active: active_after_2} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_2 == active_before + 2

      TestExpirables.clear(:github)
      %{active: active_after_clear} = DynamicSupervisor.count_children(ExpirableStore.Supervisor)
      assert active_after_clear == active_before + 1
    end

    test "agents are added to :pg groups" do
      group_github = {TestExpirables, :github}
      group_slack = {TestExpirables, :slack}

      assert :pg.get_members(:expirable_store, group_github) == []
      assert :pg.get_members(:expirable_store, group_slack) == []

      {:ok, _, _} = TestExpirables.fetch(:github)
      assert length(:pg.get_members(:expirable_store, group_github)) == 1

      {:ok, _, _} = TestExpirables.fetch(:slack)
      assert length(:pg.get_members(:expirable_store, group_slack)) == 1

      TestExpirables.clear(:github)
      assert :pg.get_members(:expirable_store, group_github) == []
      assert length(:pg.get_members(:expirable_store, group_slack)) == 1
    end

    test "local members are preferred" do
      group = {TestExpirables, :github}

      {:ok, token1, expires_at1} = TestExpirables.fetch(:github)

      [_local_pid] = :pg.get_local_members(:expirable_store, group)

      {:ok, token2, expires_at2} = TestExpirables.fetch(:github)
      assert token1 == token2
      assert expires_at1 == expires_at2
      assert_receive {:fetch, :github, _}, 100

      refute_receive {:fetch, :github, _}
    end
  end
end
