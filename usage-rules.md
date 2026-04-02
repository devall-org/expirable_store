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

  # Stateful: state persists across fetch calls
  expirable :oauth_token do
    fetch fn state ->
      {access, new_refresh} = OAuth.refresh(state.refresh_token)
      {:ok, access, System.system_time(:millisecond) + :timer.hours(1), %{state | refresh_token: new_refresh}}
    end
    require_init true
    scope :cluster
    refresh {:eager, before_expiry: :timer.minutes(5)}
  end

  # Keyed + require_init: per-tenant with runtime init
  expirable :tenant_api_key do
    fetch fn tenant_id, state ->
      api_key = ExternalAPI.rotate_key(tenant_id, state.secret)
      {:ok, api_key, System.system_time(:millisecond) + :timer.hours(24), state}
    end
    keyed true
    require_init true
    scope :cluster
    refresh :lazy
  end
end
```

## API Usage

```elixir
# Non-keyed (stateless)
MyApp.Expirables.github_access_token()   # {:ok, value, expires_at} or :error
MyApp.Expirables.github_access_token!()  # value or raises
MyApp.Expirables.fetch(:github_access_token)
MyApp.Expirables.fetch!(:github_access_token)
MyApp.Expirables.clear(:github_access_token)
MyApp.Expirables.clear_all()

# require_init: must init before fetch
MyApp.Expirables.init_oauth_token(%{refresh_token: get_from_db()})
MyApp.Expirables.oauth_token()           # {:ok, access_token, expires_at} or :error
MyApp.Expirables.init(:oauth_token, %{refresh_token: get_from_db()})  # generic form

# Keyed + require_init
MyApp.Expirables.init(:tenant_api_key, "t1", %{secret: get_secret()})
MyApp.Expirables.tenant_api_key("t1")    # {:ok, value, expires_at} or :error
MyApp.Expirables.tenant_api_key!("t1")   # value or raises
MyApp.Expirables.clear(:tenant_api_key, "t1")  # specific key
MyApp.Expirables.clear(:tenant_api_key)        # all keys
```

## DSL Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn state -> {:ok, value, expires_at, next_state} \| {:error, next_state} end` | *required* | Stateful fetch. Use 2-arity `fn key, state -> ... end` when `keyed: true`. `expires_at` is Unix ms or `:infinity` |
| `keyed` | `true`, `false` | `false` | When `true`, each unique key gets its own independent cache entry, state, and timer |
| `require_init` | `true`, `false` | `false` | When `true`, `init` must be called with initial state before fetch works |
| `refresh` | `:lazy`, `{:eager, before_expiry: ms}` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

- **Fetch state**: state starts as `nil` (or init value when `require_init: true`), persists across fetch calls. Cleared on `clear`
- **Refresh**: `:lazy` refreshes on next fetch after expiry; `{:eager, before_expiry: ms}` refreshes in background before expiry (no-op for `:infinity`)
- **Scope**: `:cluster` replicates across nodes via `:pg`; `:local` is node-local only
- **Keyed**: key can be any Erlang term; number of keys need not be known at compile time
- **require_init**: fetch returns `:error` until `init` is called; after `clear`, init is required again

## Key Behaviors

- `:error` results are never cached — fetch is retried on every call (state is preserved across retries)
- `expires_at` must be a Unix timestamp in milliseconds or `:infinity`
- Expirable names are compile-time atoms; keys are runtime values
- `clear(name)` on a keyed expirable clears all keys for that name
- `clear` destroys agent — `require_init: true` expirables need `init` again after clear

## When to Use

Good for: OAuth tokens, API keys, FX rates, per-tenant credentials (`keyed: true`).

Not recommended for: high-traffic scenarios, large values.
