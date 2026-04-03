defmodule ExpirableStore.AddFunctions do
  @moduledoc false

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    entities = Spark.Dsl.Transformer.get_entities(dsl_state, [:expirables])
    all_names = Enum.map(entities, & &1.name)
    keyed_names = entities |> Enum.filter(& &1.keyed) |> Enum.map(& &1.name)
    unkeyed_names = entities |> Enum.reject(& &1.keyed) |> Enum.map(& &1.name)

    generic_fns =
      quote do
        @__expirable_store_module__ __MODULE__
        @__all_expirable_names__ unquote(all_names)
        @__keyed_expirable_names__ unquote(keyed_names)
        @__unkeyed_expirable_names__ unquote(unkeyed_names)

        defp __validate_expirable__!(name, all_names, valid_names, caller, arity_hint) do
          if is_atom(name) do
            cond do
              name not in all_names ->
                raise CompileError,
                  file: caller.file,
                  line: caller.line,
                  description: "Unknown expirable #{inspect(name)}. Valid: #{inspect(all_names)}"

              name not in valid_names ->
                raise CompileError,
                  file: caller.file,
                  line: caller.line,
                  description: "Expirable #{inspect(name)} #{arity_hint}"

              true ->
                :ok
            end
          end
        end

        defmacro fetch(name) do
          __validate_expirable__!(name, @__all_expirable_names__, @__unkeyed_expirable_names__, __CALLER__, "is keyed; use fetch/2 with a key argument")
          quote do: ExpirableStore.fetch(unquote(@__expirable_store_module__), unquote(name))
        end

        defmacro fetch!(name) do
          __validate_expirable__!(name, @__all_expirable_names__, @__unkeyed_expirable_names__, __CALLER__, "is keyed; use fetch!/2 with a key argument")
          quote do: ExpirableStore.fetch!(unquote(@__expirable_store_module__), unquote(name))
        end

        defmacro fetch(name, key) do
          __validate_expirable__!(name, @__all_expirable_names__, @__keyed_expirable_names__, __CALLER__, "is not keyed; use fetch/1 without a key argument")
          quote do: ExpirableStore.fetch(unquote(@__expirable_store_module__), unquote(name), unquote(key))
        end

        defmacro fetch!(name, key) do
          __validate_expirable__!(name, @__all_expirable_names__, @__keyed_expirable_names__, __CALLER__, "is not keyed; use fetch!/1 without a key argument")
          quote do: ExpirableStore.fetch!(unquote(@__expirable_store_module__), unquote(name), unquote(key))
        end

        defmacro put_state(name, state) do
          __validate_expirable__!(name, @__all_expirable_names__, @__unkeyed_expirable_names__, __CALLER__, "is keyed; use put_state/3 with a key argument")
          quote do: ExpirableStore.put_state(unquote(@__expirable_store_module__), unquote(name), unquote(state))
        end

        defmacro put_state(name, key, state) do
          __validate_expirable__!(name, @__all_expirable_names__, @__keyed_expirable_names__, __CALLER__, "is not keyed; use put_state/2 without a key argument")
          quote do: ExpirableStore.put_state(unquote(@__expirable_store_module__), unquote(name), unquote(key), unquote(state))
        end

        defmacro update_state(name, fun) do
          __validate_expirable__!(name, @__all_expirable_names__, @__unkeyed_expirable_names__, __CALLER__, "is keyed; use update_state/3 with a key argument")
          quote do: ExpirableStore.update_state(unquote(@__expirable_store_module__), unquote(name), unquote(fun))
        end

        defmacro update_state(name, key, fun) do
          __validate_expirable__!(name, @__all_expirable_names__, @__keyed_expirable_names__, __CALLER__, "is not keyed; use update_state/2 without a key argument")
          quote do: ExpirableStore.update_state(unquote(@__expirable_store_module__), unquote(name), unquote(key), unquote(fun))
        end

        defmacro clear(name) do
          __validate_expirable__!(name, @__all_expirable_names__, @__all_expirable_names__, __CALLER__, "")
          quote do: ExpirableStore.clear(unquote(@__expirable_store_module__), unquote(name))
        end

        defmacro clear(name, key) do
          __validate_expirable__!(name, @__all_expirable_names__, @__keyed_expirable_names__, __CALLER__, "is not keyed; use clear/1 without a key argument")
          quote do: ExpirableStore.clear(unquote(@__expirable_store_module__), unquote(name), unquote(key))
        end

        def clear_all(), do: ExpirableStore.clear_all(__MODULE__)
      end

    {:ok, Spark.Dsl.Transformer.eval(dsl_state, [], [generic_fns])}
  end
end
