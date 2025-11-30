# ExpirableStore Usage Rules

Lightweight expirable value store for Elixir with cluster-wide or local scoping. Uses Spark DSL for compile-time definition.

## Defining Expirables

```elixir
defmodule MyApp.Expirables do
  use ExpirableStore

  expirable :github_access_token do
    # Must return {:ok, value, expires_at} or :error
    fetch fn -> GitHubOAuth.fetch_access_token() end
    scope :cluster
    refresh :lazy
  end

  expirable :local_agent_token do
    fetch fn -> Agent.fetch_local_token() end
    scope :local
    refresh :lazy
  end

  expirable :fx_rate do
    fetch fn -> FX.fetch_usd_krw() end
    scope :cluster
    refresh {:eager, before_expiry: :timer.seconds(30)}
  end
end
```

## API Usage

```elixir
# Named functions (recommended)
MyApp.Expirables.github_access_token()   # Returns {:ok, value, expires_at} or :error
MyApp.Expirables.github_access_token!()  # Returns value or raises

# Generic functions
MyApp.Expirables.fetch(:github_access_token)
MyApp.Expirables.fetch!(:github_access_token)
MyApp.Expirables.clear(:github_access_token)
MyApp.Expirables.clear_all()
```

## DSL Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn -> {:ok, value, expires_at} \| :error end` | *required* | Function to fetch the value |
| `refresh` | `:lazy`, `{:eager, before_expiry: ms}` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

### Refresh Strategies
- `:lazy` - Refresh on next fetch after expiry
- `{:eager, before_expiry: ms}` - Background refresh `ms` milliseconds before expiry

### Scope Options
- `:cluster` - Replicated across all nodes via `:pg`
- `:local` - Node-local only, no replication

## Key Behaviors

- Success results (`{:ok, value, expires_at}`) are stored until expiration
- Failure results (`:error`) are NEVER stored - fetch function is called on every attempt
- `expires_at` must be Unix timestamp in milliseconds
- Expirable names must be compile-time atoms defined in DSL, no dynamic keys

## When to Use

Good for:
- OAuth tokens, API keys, JWT tokens
- FX rates, configuration values
- Session identifiers, credentials

Not recommended for:
- High-traffic scenarios
- Dynamic keys (unbounded entries)
- Large values
