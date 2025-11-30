# ExpirableStore

Lightweight expirable value store for Elixir with cluster-wide or local scoping.

Perfect for caching OAuth tokens, API keys, and other time-sensitive data that shouldn't be repeatedly refreshed.

## Features

- **Smart storage**: Stores successes, retries failures on next fetch
- **Flexible scoping**: Cluster-wide replication or node-local storage
- **Refresh strategies**: Lazy (on-demand) or eager (background pre-refresh)
- **Concurrency-safe**: Safe concurrent access via `:global.trans/2`
- **Clean DSL**: [Spark](https://github.com/ash-project/spark)-based compile-time configuration
- **Named functions**: Auto-generated functions for each expirable (e.g., `github()`, `github!()`)

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
    # Must return {:ok, value, expires_at} or :error
    fetch fn -> GitHubOAuth.fetch_access_token() end
  end

  # Local-scoped (node-independent)
  expirable :datadog_agent_token do
    fetch fn -> DatadogAgent.fetch_local_token() end
    scope :local
  end

  # Eager refresh (background pre-refresh before expiry)
  expirable :fx_rate_usd_krw do
    fetch fn -> FX.fetch_usd_krw() end
    refresh :eager
  end
end
```

### Usage

```elixir
# Using named functions (recommended)
{:ok, token, expires_at} = MyApp.Expirables.github_access_token()
token = MyApp.Expirables.github_access_token!()

# Or using fetch with name
{:ok, token, expires_at} = MyApp.Expirables.fetch(:github_access_token)
token = MyApp.Expirables.fetch!(:github_access_token)

# Clear stored value
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
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

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

- **Node-independent**: Each node maintains its own Agent via Registry
- **No coordination**: No cluster-wide locking or synchronization
- **Use case**: Per-node secrets, local agent tokens, etc.

## When to Use

This library is optimized for **lightweight data** like:
- OAuth tokens, API keys, JWT tokens
- FX rates, configuration values
- Session identifiers, credentials

**NOT recommended for**:
- High-traffic scenarios (frequent reads/writes)
- Dynamic keys (unbounded number of entries)
- Large values

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

For each `expirable :name`, the following functions are generated:

- `name()` → `{:ok, value, expires_at}` or `:error`
- `name!()` → `value` or raises `RuntimeError`

Additionally, generic functions are available:

- `fetch(name)` → `{:ok, value, expires_at}` or `:error`
- `fetch!(name)` → `value` or raises `RuntimeError`
- `clear(name)` → `:ok`
- `clear_all()` → `:ok`

## Development

### Running Tests

```bash
# Run all tests (includes multi-node tests)
elixir --sname test -S mix test

# Run only single-node tests
mix test --exclude multi_node

# Run only multi-node tests
elixir --sname test -S mix test --only multi_node
```

Multi-node tests automatically start a local Erlang cluster using `:peer` to verify replication and synchronization across multiple nodes.
