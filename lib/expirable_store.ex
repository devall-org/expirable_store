defmodule ExpirableStore do
  @moduledoc """
  A lightweight expirable value store for Elixir.

  Provides compile-time DSL for defining expirable values with configurable
  refresh strategies and scoping (cluster-wide or local).
  """

  use Spark.Dsl, default_extensions: [extensions: [ExpirableStore.Dsl]]

  @doc """
  Sets the state for an expirable, replacing any existing state.

  Required before `fetch/2` when the expirable has `require_initial_state: true`.
  """
  def put_state(module, name, state) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.put_state(module, name, state, scope)
  end

  @doc """
  Sets the state for a keyed expirable, replacing any existing state.

  Required before `fetch/3` when the expirable has `require_initial_state: true`.
  """
  def put_state(module, name, key, state) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.put_state(module, name, key, state, scope)
  end

  @doc """
  Updates the state for an expirable by applying `fun` to the current state.

  `fun` receives the current state (or `nil` if no state exists) and must return the new state.
  """
  def update_state(module, name, fun) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.update_state(module, name, fun, scope)
  end

  @doc """
  Updates the state for a keyed expirable by applying `fun` to the current state.

  `fun` receives the current state (or `nil` if no state exists) and must return the new state.
  """
  def update_state(module, name, key, fun) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.update_state(module, name, key, fun, scope)
  end

  @doc """
  Fetch a stored value.

  Returns `{:ok, value, expires_at}` on success.
  Returns `{:error, :fetch_failed}` when the fetch function failed.
  Returns `{:error, :state_required}` when `require_initial_state: true` and `put_state` has not been called.
  """
  def fetch(module, name) do
    %{fetch: fetch_fn, scope: scope, refresh: refresh, require_initial_state: require_initial_state} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    case ExpirableStore.Store.fetch(module, name, fetch_fn, refresh, scope, require_initial_state) do
      {:ok, _, _} = ok -> ok
      :error -> {:error, :fetch_failed}
      {:error, :state_required} = err -> err
    end
  end

  @doc """
  Fetch a keyed expirable value for the given key.

  Returns `{:ok, value, expires_at}` on success.
  Returns `{:error, :fetch_failed}` when the fetch function failed.
  Returns `{:error, :state_required}` when `require_initial_state: true` and `put_state` has not been called.
  """
  def fetch(module, name, key) do
    %{fetch: fetch_fn, scope: scope, refresh: refresh, require_initial_state: require_initial_state} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    bound_fetch_fn = fn state -> fetch_fn.(key, state) end

    case ExpirableStore.Store.fetch(module, name, key, bound_fetch_fn, refresh, scope, require_initial_state) do
      {:ok, _, _} = ok -> ok
      :error -> {:error, :fetch_failed}
      {:error, :state_required} = err -> err
    end
  end

  @doc """
  Fetch a stored value, raising an exception on failure.

  Returns the value directly without expiration time.
  """
  def fetch!(module, name) do
    case fetch(module, name) do
      {:ok, value, _expires_at} -> value
      {:error, reason} -> raise "Failed to fetch expirable: #{inspect(name)}, reason: #{inspect(reason)}"
    end
  end

  @doc """
  Fetch a keyed expirable value for the given key, raising an exception on failure.

  Returns the value directly without expiration time.
  """
  def fetch!(module, name, key) do
    case fetch(module, name, key) do
      {:ok, value, _expires_at} -> value
      {:error, reason} -> raise "Failed to fetch expirable: #{inspect(name)} key=#{inspect(key)}, reason: #{inspect(reason)}"
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
