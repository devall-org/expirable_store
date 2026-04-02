# ExpirableStore Usage Rules

Lightweight expirable value store for Elixir with cluster-wide or local scoping. Uses Spark DSL for compile-time definition.

## Defining Expirables

```elixir
defmodule MyApp.Expirables do
  use ExpirableStore

  # Non-keyed: single cached value per expirable
  expirable :github_access_token do
    fetch fn -> GitHubOAuth.fetch_access_token() end
    scope :cluster
    refresh :lazy
  end

  expirable :datadog_agent_token do
    fetch fn -> DatadogAgent.fetch_local_token() end
    scope :local
    refresh {:eager, before_expiry: :timer.seconds(30)}
  end

  expirable :static_config do
    fetch fn -> {:ok, load_config(), :infinity} end
  end

  # Keyed: independent cache and timer per GitHub App installation
  expirable :github_installation_token do
    fetch fn installation_id -> GitHubApp.get_installation_token(installation_id) end
    keyed true
    scope :cluster
    refresh :lazy
  end
end
```

## API Usage

```elixir
# Non-keyed
MyApp.Expirables.github_access_token()   # {:ok, value, expires_at} or :error
MyApp.Expirables.github_access_token!()  # value or raises
MyApp.Expirables.fetch(:github_access_token)
MyApp.Expirables.fetch!(:github_access_token)
MyApp.Expirables.clear(:github_access_token)
MyApp.Expirables.clear_all()

# Keyed
MyApp.Expirables.github_installation_token(123)   # {:ok, value, expires_at} or :error
MyApp.Expirables.github_installation_token!(123)  # value or raises
MyApp.Expirables.fetch(:github_installation_token, 123)
MyApp.Expirables.fetch!(:github_installation_token, 123)
MyApp.Expirables.clear(:github_installation_token, 123)  # specific key
MyApp.Expirables.clear(:github_installation_token)       # all keys
```

## DSL Options

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `fetch` | `fn -> {:ok, value, expires_at} \| :error end` | *required* | Fetch function. Use 1-arity when `keyed: true`. `expires_at` is Unix timestamp in ms or `:infinity` |
| `keyed` | `true`, `false` | `false` | When `true`, each unique key gets its own independent cache entry and timer |
| `refresh` | `:lazy`, `{:eager, before_expiry: ms}` | `:lazy` | Refresh strategy |
| `scope` | `:cluster`, `:local` | `:cluster` | Scope of the store |

- **Refresh**: `:lazy` refreshes on next fetch after expiry; `{:eager, before_expiry: ms}` refreshes in background before expiry (no-op for `:infinity`)
- **Scope**: `:cluster` replicates across nodes via `:pg`; `:local` is node-local only
- **Keyed**: key can be any Erlang term; number of keys need not be known at compile time

## Key Behaviors

- `:error` results are never cached — fetch is retried on every call
- `expires_at` must be a Unix timestamp in milliseconds or `:infinity`
- Expirable names are compile-time atoms; keys are runtime values
- `clear(name)` on a keyed expirable clears all keys for that name

## When to Use

Good for: OAuth tokens, API keys, FX rates, per-tenant credentials (`keyed: true`).

Not recommended for: high-traffic scenarios, large values.
