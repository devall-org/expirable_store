defmodule ExpirableStore do
  @moduledoc """
  A lightweight expirable value store for Elixir.

  Provides compile-time DSL for defining expirable values with configurable
  refresh strategies and scoping (cluster-wide or local).
  """

  use Spark.Dsl, default_extensions: [extensions: [ExpirableStore.Dsl]]

  @doc """
  Fetch a stored value, returning `{:ok, value, expires_at}` on success or `:error` on failure.

  The fetch function must return `{:ok, value, expires_at}` where `expires_at` is a Unix
  timestamp in milliseconds, or `:error`.
  """
  def fetch(module, name) do
    %{fetch: fetch_fn, scope: scope, refresh: refresh} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    result = ExpirableStore.Store.fetch(module, name, fetch_fn, refresh, scope)
    to_external(result)
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
  Clear a specific expirable by name.
  """
  def clear(module, name) do
    %{scope: scope} =
      ExpirableStore.Info.expirables(module) |> Enum.find(fn e -> e.name == name end)

    ExpirableStore.Store.clear(module, name, scope)
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

  # ===========================================================================
  # Helpers
  # ===========================================================================

  # Convert internal Agent state to external format (for API return)
  defp to_external({:__ready__, value, expires_at}), do: {:ok, value, expires_at}
  defp to_external(:__error__), do: :error
end
