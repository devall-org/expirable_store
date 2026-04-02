# Changelog

## v0.5.0 (2026-04-02)

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
