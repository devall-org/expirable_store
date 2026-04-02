defmodule ExpirableStore.Dsl do
  @moduledoc false

  defmodule Expirable do
    defstruct [:name, :fetch, :refresh, :scope, :keyed, :require_init, :__spark_metadata__]
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
      require_init: [
        type: :boolean,
        required: false,
        default: false,
        doc:
          "When true, init/2 (or init/3 for keyed) must be called with initial state before fetch works. Allows runtime value injection into the fetch state."
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
