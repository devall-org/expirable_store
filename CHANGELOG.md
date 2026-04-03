# Changelog

## v0.7.1 (2026-04-03)

- Fix `.formatter.exs` to use correct DSL option name `require_initial_state` (was `require_init`)

## v0.7.0 (2026-04-03)

- **Breaking**: Remove per-name generated functions (`name()`, `name!()`, `name(key)`, `name!(key)`, `init_name/1,2`) — use generic functions instead
- **Breaking**: Rename `require_init` DSL option to `require_initial_state`
- **Breaking**: Rename `init/2,3` to `put_state/2,3` (replaces state) and add `update_state/2,3` (transforms state via function)
- **Breaking**: `fetch/2,3` now returns `{:error, reason}` instead of bare `:error`
  - `{:error, :fetch_failed}` — the fetch function returned an error
  - `{:error, :state_required}` — `require_initial_state: true` and `put_state`/`update_state` has not been called
- Add compile-time name validation — `require MyApp.Expirables` to get `CompileError` for unknown names and keyed/unkeyed arity mismatches at build time

Migration:
- `MyApp.Expirables.oauth_token()` → `MyApp.Expirables.fetch(:oauth_token)`
- `MyApp.Expirables.oauth_token!()` → `MyApp.Expirables.fetch!(:oauth_token)`
- `MyApp.Expirables.init_oauth_token(state)` → `MyApp.Expirables.put_state(:oauth_token, state)`
- `require_init true` → `require_initial_state true`
- `init(name, state)` → `put_state(name, state)`
- `:error = fetch(name)` → `{:error, _} = fetch(name)` (or match on specific reason)

## v0.6.0 (2026-04-02)

- **Breaking**: Fetch functions are now stateful — receive `state`, must return `next_state`
  - Non-keyed: `fn state -> {:ok, value, expires_at, next_state} | {:error, next_state}`
  - Keyed: `fn key, state -> {:ok, value, expires_at, next_state} | {:error, next_state}`
- Add `require_init` option — when `true`, `init` must be called with initial state before fetch works
- Auto-generate `init_<name>/1` (non-keyed) and `init_<name>/2` (keyed) functions for `require_init: true` expirables
- Add generic `init/2` and `init/3` functions

## v0.5.0 (2026-04-01)

- Add `keyed: true` option for per-key independent cache entries and timers
- Keyed fetch functions accept a runtime key argument (any Erlang term)
- `clear(name, key)` clears a specific key; `clear(name)` clears all keys for the name
- `clear_all()` includes keyed expirables

## v0.4.2

- Refactor `AddFunctions` transformer for clarity

## v0.4.1

- Add scope and refresh strategy info to generated function docs

## v0.4.0

- Rename project from `NanoGlobalCache` to `ExpirableStore`
- Rewrite DSL using [Spark](https://github.com/ash-project/spark)
- Add `scope :cluster | :local` option
- Add `refresh :lazy | {:eager, before_expiry: ms}` option
- Support `:infinity` for never-expiring values
- Cluster replication via `:pg`; concurrency safety via `:global.trans/2`
- Auto-generate named functions per expirable (`name()` / `name!()`)
