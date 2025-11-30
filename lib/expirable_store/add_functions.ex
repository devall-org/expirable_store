defmodule ExpirableStore.AddFunctions do
  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    expirables = Spark.Dsl.Transformer.get_entities(dsl_state, [:expirables])

    # Generate named functions for each expirable
    named_functions =
      Enum.flat_map(expirables, fn %{name: name} ->
        bang_name = String.to_atom("#{name}!")

        [
          quote do
            @doc "Fetch the `#{unquote(name)}` expirable value"
            def unquote(name)() do
              ExpirableStore.fetch(__MODULE__, unquote(name))
            end

            @doc "Fetch the `#{unquote(name)}` expirable value, raises on error"
            def unquote(bang_name)() do
              ExpirableStore.fetch!(__MODULE__, unquote(name))
            end
          end
        ]
      end)

    # Generic functions
    generic_functions =
      quote do
        def fetch(name) do
          ExpirableStore.fetch(__MODULE__, name)
        end

        def fetch!(name) do
          ExpirableStore.fetch!(__MODULE__, name)
        end

        def clear(name) do
          ExpirableStore.clear(__MODULE__, name)
        end

        def clear_all() do
          ExpirableStore.clear_all(__MODULE__)
        end
      end

    {:ok,
     dsl_state
     |> Spark.Dsl.Transformer.eval([], [generic_functions | named_functions])}
  end
end
