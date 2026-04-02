defmodule ExpirableStore.AddFunctions do
  @moduledoc false

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    expirables = Spark.Dsl.Transformer.get_entities(dsl_state, [:expirables])

    per_expirable_fns =
      Enum.map(expirables, fn %{name: name, scope: scope, refresh: refresh, keyed: keyed} ->
        bang_name = String.to_atom("#{name}!")
        scope_str = inspect(scope)
        refresh_str = inspect(refresh)
        args = if keyed, do: [quote do: key], else: []
        keyed_doc = if keyed, do: "\n- keyed: true", else: ""

        quote do
          @doc """
          Fetch the `#{unquote(name)}` expirable value.

          - scope: #{unquote(scope_str)}
          - refresh: #{unquote(refresh_str)}#{unquote(keyed_doc)}
          """
          def unquote(name)(unquote_splicing(args)) do
            ExpirableStore.fetch(__MODULE__, unquote(name), unquote_splicing(args))
          end

          @doc """
          Fetch the `#{unquote(name)}` expirable value, raises on error.

          - scope: #{unquote(scope_str)}
          - refresh: #{unquote(refresh_str)}#{unquote(keyed_doc)}
          """
          def unquote(bang_name)(unquote_splicing(args)) do
            ExpirableStore.fetch!(__MODULE__, unquote(name), unquote_splicing(args))
          end
        end
      end)

    generic_fns =
      quote do
        def fetch(name), do: ExpirableStore.fetch(__MODULE__, name)
        def fetch!(name), do: ExpirableStore.fetch!(__MODULE__, name)
        def fetch(name, key), do: ExpirableStore.fetch(__MODULE__, name, key)
        def fetch!(name, key), do: ExpirableStore.fetch!(__MODULE__, name, key)
        def clear(name), do: ExpirableStore.clear(__MODULE__, name)
        def clear(name, key), do: ExpirableStore.clear(__MODULE__, name, key)
        def clear_all(), do: ExpirableStore.clear_all(__MODULE__)
      end

    {:ok,
     dsl_state
     |> Spark.Dsl.Transformer.eval([], [generic_fns | per_expirable_fns])}
  end
end
