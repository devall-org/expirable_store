# ExpirableStore

[![CI](https://github.com/devall-org/expirable_store/actions/workflows/ci.yml/badge.svg)](https://github.com/devall-org/expirable_store/actions/workflows/ci.yml)

Lightweight expirable value store for Elixir with cluster-wide or local scoping.

Perfect for caching OAuth tokens, API keys, and other time-sensitive data that shouldn't be repeatedly refreshed.

## Features

- **Smart caching**: Caches successful results, retries on failure
- **Flexible scoping**: Cluster-wide replication or node-local storage
- **Refresh strategies**: Lazy (on-demand) or eager (background pre-refresh)
- **Keyed expirables**: Same logic, independent cache and timer per runtime key
- **Concurrency-safe**: Concurrent access protected by `:global.trans/2`
- **Clean DSL**: [Spark](https://github.com/ash-project/spark)-based compile-time configuration
- **Named functions**: Auto-generated functions for each expirable

## Installation

```elixir
def deps do
  [{:expirable_store, "~> 0.5.0"}]
end
```

## Quick Example

```elixir
defmodule MyApp.Expirables do
  use ExpirableStore

  # Cluster-scoped, lazy refresh
  expirable :github_access_token do
    fetch fn -> GitHubOAuth.fetch_access_token() end
    scope :cluster
    refresh :lazy
  end

  # Node-local, eager refresh (30s before expiry)
  expirable :datadog_agent_token do
    fetch fn -> DatadogAgent.fetch_local_token() end
    scope :local
    refresh {:eager, before_expiry: :timer.seconds(30)}
  end

  # Never expires (cached until explicitly cleared)
  expirable :static_config do
    fetch fn -> {:ok, load_config(), :infinity} end
  end

  # Keyed: independent cache and timer per GitHub App installation
  expirable :github_installation_token do
    fetch fn installation_id ->
      {:ok, GitHubApp.get_installation_token(installation_id), System.system_time(:millisecond) + :timer.hours(1)}
    end
    keyed true
    scope :cluster
    refresh {:eager, before_expiry: :timer.minutes(5)}
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

# Keyed: pass a runtime key
{:ok, token, _} = MyApp.Expirables.github_installation_token(123)
token = MyApp.Expirables.github_installation_token!(123)
MyApp.Expirables.clear(:github_installation_token, 123)  # clear specific key
MyApp.Expirables.clear(:github_installation_token)       # clear all keys
```

## DSL Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn -> {:ok, value, expires_at} \| :error end` | *required* | Fetch function. Use 1-arity when `keyed: true`. `expires_at` is Unix timestamp in ms or `:infinity` |
| `keyed` | `true`, `false` | `false` | When `true`, each unique key gets its own independent cache entry and timer |
| `refresh` | `:lazy`, `{:eager, before_expiry: ms}` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

### Refresh Strategies

- **`:lazy`** (default): Refresh on next fetch after expiry
- **`{:eager, before_expiry: ms}`**: Background refresh `ms` milliseconds before expiry. Does not apply to `:infinity` values

### Scope Options

- **`:cluster`** (default): Each node maintains a local Agent copy; updates coordinated via `:global.trans/2` and replicated via `:pg`
- **`:local`**: Node-local Agent, no cross-node replication

### Keyed Expirables

When `keyed: true`, the fetch function receives the key as its argument. Each unique key has its own independent Agent and refresh timer. The key can be any Erlang term:

```elixir
MyApp.Expirables.github_installation_token(123)        # integer
MyApp.Expirables.github_installation_token(:tenant_a)  # atom
MyApp.Expirables.github_installation_token({:org, 42}) # tuple
```

## Generated Functions

For `expirable :name` (`keyed: false`):
- `name()` / `name!()` — fetch value or raise

For `expirable :name` (`keyed: true`):
- `name(key)` / `name!(key)` — fetch value for key or raise

Generic functions (always available):
- `fetch(name)` / `fetch(name, key)`
- `fetch!(name)` / `fetch!(name, key)`
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
