defmodule ExpirableStore do
  @moduledoc """
  A lightweight expirable value store for Elixir.

  Provides compile-time DSL for defining expirable values with configurable
  refresh strategies and scoping (cluster-wide or local).
  """

  use Spark.Dsl, default_extensions: [extensions: [ExpirableStore.Dsl]]

  @doc """
  Initialize the state for an expirable that has `require_init: true`.

  Must be called before `fetch/2` for the given expirable.
  """
  def init(module, name, init_state) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.init(module, name, init_state, scope)
  end

  @doc """
  Initialize the state for a keyed expirable that has `require_init: true`.

  Must be called before `fetch/3` for the given key.
  """
  def init(module, name, key, init_state) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.init(module, name, key, init_state, scope)
  end

  @doc """
  Fetch a stored value, returning `{:ok, value, expires_at}` on success or `:error` on failure.

  The fetch function receives state and must return `{:ok, value, expires_at, next_state}`
  or `{:error, next_state}`.
  """
  def fetch(module, name) do
    %{fetch: fetch_fn, scope: scope, refresh: refresh, require_init: require_init} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.fetch(module, name, fetch_fn, refresh, scope, require_init)
  end

  @doc """
  Fetch a keyed expirable value for the given key.

  Returns `{:ok, value, expires_at}` on success or `:error` on failure.
  Each unique key has its own independent cache entry and timer.
  """
  def fetch(module, name, key) do
    %{fetch: fetch_fn, scope: scope, refresh: refresh, require_init: require_init} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    bound_fetch_fn = fn state -> fetch_fn.(key, state) end
    ExpirableStore.Store.fetch(module, name, key, bound_fetch_fn, refresh, scope, require_init)
  end

  @doc """
  Fetch a stored value, raising an exception on failure.

  Returns the value directly without expiration time.
  """
  def fetch!(module, name) do
    case fetch(module, name) do
      {:ok, value, _expires_at} -> value
      :error -> raise "Failed to fetch expirable: #{inspect(name)}"
    end
  end

  @doc """
  Fetch a keyed expirable value for the given key, raising an exception on failure.

  Returns the value directly without expiration time.
  """
  def fetch!(module, name, key) do
    case fetch(module, name, key) do
      {:ok, value, _expires_at} -> value
      :error -> raise "Failed to fetch expirable: #{inspect(name)} key=#{inspect(key)}"
    end
  end

  @doc """
  Clear a specific expirable by name.

  For keyed expirables, clears all keys for that expirable.
  Use `clear/3` to clear a specific key.
  """
  def clear(module, name) do
    %{scope: scope, keyed: keyed} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    if keyed do
      ExpirableStore.Store.clear_keyed_family(module, name, scope)
    else
      ExpirableStore.Store.clear(module, name, scope)
    end
  end

  @doc """
  Clear a specific key from a keyed expirable.
  """
  def clear(module, name, key) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.clear(module, name, key, scope)
  end

  @doc """
  Clear all expirables for a module.
  """
  def clear_all(module) do
    ExpirableStore.Info.expirables(module)
    |> Enum.each(fn %{name: name} ->
      ExpirableStore.clear(module, name)
    end)
  end
end
