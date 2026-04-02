# ExpirableStore

[![CI](https://github.com/devall-org/expirable_store/actions/workflows/ci.yml/badge.svg)](https://github.com/devall-org/expirable_store/actions/workflows/ci.yml)

Lightweight expirable value store for Elixir with cluster-wide or local scoping.

Perfect for caching OAuth tokens, API keys, and other time-sensitive data that shouldn't be repeatedly refreshed.

## Features

- **Smart caching**: Caches successful results, retries on failure
- **Stateful fetch**: Fetch function receives and returns state, persisted across calls
- **Flexible scoping**: Cluster-wide replication or node-local storage
- **Refresh strategies**: Lazy (on-demand) or eager (background pre-refresh)
- **Keyed expirables**: Same logic, independent cache and timer per runtime key
- **Runtime init**: `require_init` option for injecting runtime values before first fetch
- **Concurrency-safe**: Concurrent access protected by `:global.trans/2`
- **Clean DSL**: [Spark](https://github.com/ash-project/spark)-based compile-time configuration
- **Named functions**: Auto-generated functions for each expirable

## Installation

```elixir
def deps do
  [{:expirable_store, "~> 0.6.0"}]
end
```

## Quick Example

```elixir
defmodule MyApp.Expirables do
  use ExpirableStore

  # Cluster-scoped, lazy refresh (stateless — ignores state)
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

  # Node-local, eager refresh (30s before expiry)
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
      refresh_token = state.refresh_token
      {access_token, new_refresh_token} = OAuth.refresh(refresh_token)
      expires_at = System.system_time(:millisecond) + :timer.hours(1)
      {:ok, access_token, expires_at, %{state | refresh_token: new_refresh_token}}
    end
    require_init true
    scope :cluster
    refresh {:eager, before_expiry: :timer.minutes(5)}
  end

  # Keyed + require_init: per-tenant credentials with runtime init
  expirable :tenant_api_key do
    fetch fn tenant_id, state ->
      api_key = ExternalAPI.rotate_key(tenant_id, state.secret)
      expires_at = System.system_time(:millisecond) + :timer.hours(24)
      {:ok, api_key, expires_at, state}
    end
    keyed true
    require_init true
    scope :cluster
    refresh :lazy
  end
end
```

```elixir
# Non-keyed: named functions (recommended)
{:ok, token, expires_at} = MyApp.Expirables.github_access_token()
token = MyApp.Expirables.github_access_token!()

# Non-keyed: generic functions
{:ok, token, _} = MyApp.Expirables.fetch(:github_access_token)
MyApp.Expirables.clear(:github_access_token)
MyApp.Expirables.clear_all()

# require_init: must init before fetch
MyApp.Expirables.init_oauth_token(%{refresh_token: get_from_db()})
{:ok, access_token, _} = MyApp.Expirables.oauth_token()

# Keyed + require_init
MyApp.Expirables.init(:tenant_api_key, "tenant_123", %{secret: get_secret()})
{:ok, key, _} = MyApp.Expirables.tenant_api_key("tenant_123")
MyApp.Expirables.clear(:tenant_api_key, "tenant_123")  # clear specific key
MyApp.Expirables.clear(:tenant_api_key)                 # clear all keys
```

## DSL Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn state -> {:ok, value, expires_at, next_state} \| {:error, next_state} end` | *required* | Stateful fetch function. Use 2-arity `fn key, state -> ... end` when `keyed: true`. `expires_at` is Unix ms or `:infinity` |
| `keyed` | `true`, `false` | `false` | When `true`, each unique key gets its own independent cache entry and timer |
| `require_init` | `true`, `false` | `false` | When `true`, `init` must be called with initial state before fetch works |
| `refresh` | `:lazy`, `{:eager, before_expiry: ms}` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

### Refresh Strategies

- **`:lazy`** (default): Refresh on next fetch after expiry
- **`{:eager, before_expiry: ms}`**: Background refresh `ms` milliseconds before expiry. Does not apply to `:infinity` values

### Scope Options

- **`:cluster`** (default): Each node maintains a local Agent copy; updates coordinated via `:global.trans/2` and replicated via `:pg`
- **`:local`**: Node-local Agent, no cross-node replication

### Keyed Expirables

When `keyed: true`, the fetch function receives the key as its first argument and state as its second. Each unique key has its own independent Agent, state, and refresh timer. The key can be any Erlang term:

```elixir
MyApp.Expirables.tenant_api_key("tenant_123")        # string
MyApp.Expirables.tenant_api_key(:tenant_a)            # atom
MyApp.Expirables.tenant_api_key({:org, 42})           # tuple
```

### Stateful Fetch

The fetch function receives a `state` argument and must return `next_state`. State is persisted in the Agent and passed to subsequent fetch calls (e.g., on expiry refresh). When `require_init: false` (default), state starts as `nil`.

### require_init

When `require_init: true`, the expirable must be initialized at runtime before fetch works. This allows injecting runtime values (e.g., DB lookups, config) into the fetch state:

```elixir
# Must call init before fetch — otherwise fetch returns :error
MyApp.Expirables.init_oauth_token(%{refresh_token: get_from_db()})
{:ok, token, _} = MyApp.Expirables.oauth_token()

# After clear, init is required again
MyApp.Expirables.clear(:oauth_token)
:error = MyApp.Expirables.fetch(:oauth_token)
```

## Generated Functions

For `expirable :name` (`keyed: false`):
- `name()` / `name!()` — fetch value or raise

For `expirable :name` (`keyed: true`):
- `name(key)` / `name!(key)` — fetch value for key or raise

For `expirable :name` (`require_init: true`):
- `init_name(state)` — initialize state (non-keyed)
- `init_name(key, state)` — initialize state (keyed)

Generic functions (always available):
- `fetch(name)` / `fetch(name, key)`
- `fetch!(name)` / `fetch!(name, key)`
- `init(name, state)` / `init(name, key, state)`
- `clear(name)` / `clear(name, key)`
- `clear_all()`

## Key Behaviors

- `:error` results are never cached — fetch is retried on every call
- `expires_at` must be a Unix timestamp in milliseconds or `:infinity`
- For keyed expirables, the number of keys need not be known at compile time

## When to Use

Good for lightweight, time-sensitive data: OAuth tokens, API keys, FX rates, per-tenant credentials.

**Not recommended for**: high-traffic scenarios, large values.

## Development

```bash
mix test        # single-node tests
mix test.all    # includes distributed multi-node tests
```
