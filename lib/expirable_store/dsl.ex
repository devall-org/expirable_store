defmodule ExpirableStore.Dsl do
  @moduledoc false

  defmodule Expirable do
    defstruct [:name, :fetch, :refresh, :scope, :keyed, :require_initial_state, :__spark_metadata__]
  end

  @expirable %Spark.Dsl.Entity{
    name: :expirable,
    args: [:name],
    target: Expirable,
    describe: "An expirable value with configurable refresh and scope",
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The name of the expirable"
      ],
      fetch: [
        type: {:or, [{:fun, 1}, {:fun, 2}]},
        required: true,
        doc:
          "Function that receives state and returns {:ok, value, expires_at, next_state} or {:error, next_state}. expires_at is Unix timestamp in milliseconds, or :infinity for values that never expire. Use a 2-arity function (key, state) when keyed: true."
      ],
      keyed: [
        type: :boolean,
        required: false,
        default: false,
        doc:
          "When true, each unique key argument gets its own independent cache entry and timer. The fetch function must accept one argument (the key)."
      ],
      refresh: [
        type:
          {:or,
           [
             {:literal, :lazy},
             {:tuple, [{:literal, :eager}, :keyword_list]}
           ]},
        required: false,
        default: :lazy,
        doc: ":lazy or {:eager, before_expiry: milliseconds}"
      ],
      scope: [
        type: {:one_of, [:cluster, :local]},
        required: false,
        default: :cluster,
        doc: ":cluster (replicated across nodes) or :local (node-local only)"
      ],
      require_initial_state: [
        type: :boolean,
        required: false,
        default: false,
        doc:
          "When true, set_initial_state/2 (or set_initial_state/3 for keyed) must be called before fetch works. Use this when the fetch function cannot produce a valid initial state on its own (e.g. needs a refresh token from the database). When false (default), the fetch function receives nil on the first call and can initialize state itself."
      ]
    ]
  }

  @expirables %Spark.Dsl.Section{
    name: :expirables,
    schema: [],
    entities: [@expirable],
    top_level?: true,
    describe: "Define expirable values with refresh strategy and scope"
  }

  use Spark.Dsl.Extension, sections: [@expirables], transformers: [ExpirableStore.AddFunctions]
end
