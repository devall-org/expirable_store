defmodule ExpirableStore.AddFunctions do
  @moduledoc false

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    expirables = Spark.Dsl.Transformer.get_entities(dsl_state, [:expirables])

    per_expirable_fns =
      Enum.map(expirables, fn %{
                                name: name,
                                scope: scope,
                                refresh: refresh,
                                keyed: keyed,
                                require_init: require_init
                              } ->
        bang_name = String.to_atom("#{name}!")
        init_name = String.to_atom("init_#{name}")
        scope_str = inspect(scope)
        refresh_str = inspect(refresh)
        fetch_args = if keyed, do: [quote(do: key)], else: []
        init_args = if keyed, do: [quote(do: key), quote(do: state)], else: [quote(do: state)]
        keyed_doc = if keyed, do: "\n- keyed: true", else: ""
        require_init_doc = if require_init, do: "\n- require_init: true", else: ""

        init_fn =
          if require_init do
            quote do
              @doc """
              Initialize state for the `#{unquote(name)}` expirable.

              Must be called before fetching when `require_init: true`.
              """
              def unquote(init_name)(unquote_splicing(init_args)) do
                ExpirableStore.init(__MODULE__, unquote(name), unquote_splicing(init_args))
              end
            end
          end

        quote do
          @doc """
          Fetch the `#{unquote(name)}` expirable value.

          - scope: #{unquote(scope_str)}
          - refresh: #{unquote(refresh_str)}#{unquote(keyed_doc)}#{unquote(require_init_doc)}
          """
          def unquote(name)(unquote_splicing(fetch_args)) do
            ExpirableStore.fetch(__MODULE__, unquote(name), unquote_splicing(fetch_args))
          end

          @doc """
          Fetch the `#{unquote(name)}` expirable value, raises on error.

          - scope: #{unquote(scope_str)}
          - refresh: #{unquote(refresh_str)}#{unquote(keyed_doc)}#{unquote(require_init_doc)}
          """
          def unquote(bang_name)(unquote_splicing(fetch_args)) do
            ExpirableStore.fetch!(__MODULE__, unquote(name), unquote_splicing(fetch_args))
          end

          unquote(init_fn)
        end
      end)

    generic_fns =
      quote do
        def fetch(name), do: ExpirableStore.fetch(__MODULE__, name)
        def fetch!(name), do: ExpirableStore.fetch!(__MODULE__, name)
        def fetch(name, key), do: ExpirableStore.fetch(__MODULE__, name, key)
        def fetch!(name, key), do: ExpirableStore.fetch!(__MODULE__, name, key)
        def init(name, state), do: ExpirableStore.init(__MODULE__, name, state)
        def init(name, key, state), do: ExpirableStore.init(__MODULE__, name, key, state)
        def clear(name), do: ExpirableStore.clear(__MODULE__, name)
        def clear(name, key), do: ExpirableStore.clear(__MODULE__, name, key)
        def clear_all(), do: ExpirableStore.clear_all(__MODULE__)
      end

    {:ok,
     dsl_state
     |> Spark.Dsl.Transformer.eval([], [generic_fns | per_expirable_fns])}
  end
end
