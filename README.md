# ExpirableStore

Lightweight expirable value store for Elixir with cluster-wide or local scoping.

Perfect for caching OAuth tokens, API keys, and other time-sensitive data that shouldn't be repeatedly refreshed.

## Features

- **Smart caching**: Caches successes, retries failures on next fetch
- **Flexible scoping**: Cluster-wide replication or node-local storage
- **Refresh strategies**: Lazy (on-demand) or eager (background pre-refresh)
- **Concurrency-safe**: Safe concurrent access via `:global.trans/2`
- **Clean DSL**: [Spark](https://github.com/ash-project/spark)-based compile-time configuration

## Installation

```elixir
def deps do
  [{:expirable_store, "~> 0.1.0"}]
end
```

## Quick Example

```elixir
defmodule MyApp.Expirables do
  use ExpirableStore

  # Cluster-scoped, lazy refresh (default)
  expirable :github_access_token do
    fetch fn ->
      {:ok, token, exp} = GitHubOAuth.fetch_access_token()
      {:ok, token, exp}
    end
  end

  # Local-scoped (node-independent)
  expirable :datadog_agent_token do
    fetch fn ->
      {:ok, token, exp} = DatadogAgent.fetch_local_token()
      {:ok, token, exp}
    end

    scope :local
  end

  # Eager refresh (background pre-refresh before expiry)
  expirable :fx_rate_usd_krw do
    fetch fn ->
      {:ok, rate, exp} = FX.fetch_usd_krw()
      {:ok, rate, exp}
    end

    refresh :eager
    scope :cluster
  end
end
```

### Usage

```elixir
# Pattern match on result with expiration time
{:ok, token, expires_at} = MyApp.Expirables.fetch(:github_access_token)

# Or use bang version (returns value directly, raises on error)
token = MyApp.Expirables.fetch!(:github_access_token)

# Clear cache
MyApp.Expirables.clear(:github_access_token)
MyApp.Expirables.clear_all()
```

## DSL Options

### `expirable`

Define an expirable value with the following options:

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn -> {:ok, value, expires_at} \| :error end` | *required* | Function to fetch the value |
| `refresh` | `:lazy`, `:eager` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the cache |

### Refresh Strategies

- **`:lazy`** (default): Refresh on next fetch after expiry
- **`:eager`**: Background refresh at 90% of TTL (before expiry)

### Scope Options

- **`:cluster`** (default): Replicated across all nodes via `:pg`
- **`:local`**: Node-local only, no replication

## How It Works

### Cluster Scope (`:cluster`)

- **Read replicas**: Each node maintains a local Agent copy for lock-free reads
- **Coordination**: Updates coordinated via `:global.trans/2` to prevent race conditions
- **Replication**: Uses `:pg` for agent group membership across cluster

### Local Scope (`:local`)

- **Node-independent**: Each node maintains its own ETS-backed cache
- **No coordination**: No cluster-wide locking or synchronization
- **Use case**: Per-node secrets, local agent tokens, etc.

## When to Use

This library is optimized for **lightweight data** like:
- OAuth tokens, API keys, JWT tokens
- FX rates, configuration values
- Session identifiers, cached credentials

**NOT recommended for**:
- High-traffic scenarios (frequent reads/writes)
- Dynamic cache keys (unbounded number of entries)
- Large cache values

For more demanding use cases, consider [Cachex](https://github.com/whitfin/cachex) or [Nebulex](https://github.com/cabol/nebulex).

## API Reference

### Define Expirables

```elixir
expirable :name do
  fetch fn ->
    # Must return {:ok, value, expires_at} or :error
    # expires_at is Unix timestamp in milliseconds
    {:ok, value, System.system_time(:millisecond) + ttl_ms}
  end

  refresh :lazy    # or :eager
  scope :cluster   # or :local
end
```

### Generated Functions

- `fetch(name)` → `{:ok, value, expires_at}` or `:error`
- `fetch!(name)` → `value` or raises `RuntimeError`
- `clear(name)` → `:ok`
- `clear_all()` → `:ok`

## Development

### Running Tests

```bash
# Run all tests (includes cluster tests)
elixir --sname test -S mix test

# Run only local tests (no cluster)
mix test --exclude cluster

# Run only cluster tests
elixir --sname test -S mix test --only cluster
```

Cluster tests automatically start a local Erlang cluster using `:peer` to verify replication and synchronization across multiple nodes.
