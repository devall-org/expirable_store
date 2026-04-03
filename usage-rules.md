# ExpirableStore Usage Rules

Lightweight expirable value store for Elixir with cluster-wide or local scoping. Uses Spark DSL for compile-time definition.

## Defining Expirables

Fetch functions are **stateful**: they receive `state` and must return `next_state`. For stateless usage, ignore state and return `nil`.

```elixir
defmodule MyApp.Expirables do
  use ExpirableStore

  # Stateless: ignore state, return nil
  expirable :github_access_token do
    fetch fn _state ->
      case GitHubOAuth.fetch_access_token() do
        {:ok, token, expires_at} -> {:ok, token, expires_at, nil}
        :error -> {:error, nil}
      end
    end
    scope :cluster
    refresh :lazy
  end

  expirable :datadog_agent_token do
    fetch fn _state ->
      case DatadogAgent.fetch_local_token() do
        {:ok, token, expires_at} -> {:ok, token, expires_at, nil}
        :error -> {:error, nil}
      end
    end
    scope :local
    refresh {:eager, before_expiry: :timer.seconds(30)}
  end

  # Stateful + externally initialized: needs runtime state before first fetch
  expirable :oauth_token do
    fetch fn state ->
      {access, new_refresh} = OAuth.refresh(state.refresh_token)
      {:ok, access, System.system_time(:millisecond) + :timer.hours(1), %{state | refresh_token: new_refresh}}
    end
    require_initial_state true
    scope :cluster
    refresh {:eager, before_expiry: :timer.minutes(5)}
  end

  # Keyed + require_initial_state: per-tenant with runtime state
  expirable :tenant_api_key do
    fetch fn tenant_id, state ->
      api_key = ExternalAPI.rotate_key(tenant_id, state.secret)
      {:ok, api_key, System.system_time(:millisecond) + :timer.hours(24), state}
    end
    keyed true
    require_initial_state true
    scope :cluster
    refresh :lazy
  end
end
```

## API Usage

Add `require MyApp.Expirables` to get compile-time errors for unknown names and keyed/unkeyed arity mismatches. Without `require`, calls still work at runtime.

```elixir
require MyApp.Expirables  # enables compile-time name validation

# Non-keyed (stateless)
MyApp.Expirables.fetch(:github_access_token)   # {:ok, value, expires_at} or {:error, :fetch_failed}
MyApp.Expirables.fetch!(:github_access_token)  # value or raises
MyApp.Expirables.clear(:github_access_token)
MyApp.Expirables.clear_all()

# require_initial_state: must call put_state before fetch
MyApp.Expirables.put_state(:oauth_token, %{refresh_token: get_from_db()})
MyApp.Expirables.fetch(:oauth_token)           # {:ok, access_token, expires_at} or {:error, :state_required}

# Keyed + require_initial_state
MyApp.Expirables.put_state(:tenant_api_key, "t1", %{secret: get_secret()})
MyApp.Expirables.update_state(:tenant_api_key, "t1", fn old -> Map.put(old, :rotated, true) end)
MyApp.Expirables.fetch(:tenant_api_key, "t1")  # {:ok, value, expires_at} or {:error, reason}
MyApp.Expirables.fetch!(:tenant_api_key, "t1") # value or raises
MyApp.Expirables.clear(:tenant_api_key, "t1")  # specific key
MyApp.Expirables.clear(:tenant_api_key)        # all keys
```

## DSL Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn state -> {:ok, value, expires_at, next_state} \| {:error, next_state} end` | *required* | Stateful fetch. Use 2-arity `fn key, state -> ... end` when `keyed: true`. `expires_at` is Unix ms or `:infinity` |
| `keyed` | `true`, `false` | `false` | When `true`, each unique key gets its own independent cache entry, state, and timer |
| `require_initial_state` | `true`, `false` | `false` | When `true`, `put_state` must be called before fetch works. Use when the fetch function cannot produce a valid initial state on its own (e.g. needs a refresh token from the database) |
| `refresh` | `:lazy`, `{:eager, before_expiry: ms}` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

- **Fetch state**: state starts as `nil` when `require_initial_state: false` (default); the fetch function receives `nil` on the first call and can initialize state itself. When `require_initial_state: true`, fetch is blocked until `put_state` is called
- **Refresh**: `:lazy` refreshes on next fetch after expiry; `{:eager, before_expiry: ms}` refreshes in background before expiry (no-op for `:infinity`)
- **Scope**: `:cluster` replicates across nodes via `:pg`; `:local` is node-local only
- **Keyed**: key can be any Erlang term; number of keys need not be known at compile time
- **require_initial_state**: fetch returns `{:error, :state_required}` until `put_state` or `update_state` is called; after `clear`, it is required again
- **Compile-time validation**: all public functions are macros — `require` the module to catch unknown names or keyed/unkeyed arity mismatches at compile time

## Key Behaviors

- `:error` results are never cached — fetch is retried on every call (state is preserved across retries)
- `expires_at` must be a Unix timestamp in milliseconds or `:infinity`
- Expirable names are compile-time atoms; keys are runtime values
- `clear(name)` on a keyed expirable clears all keys for that name
- `clear` destroys agent — `require_initial_state: true` expirables need `put_state` again after clear

## When to Use

Good for: OAuth tokens, API keys, FX rates, per-tenant credentials (`keyed: true`).

Not recommended for: high-traffic scenarios, large values.
