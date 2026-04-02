defmodule ExpirableStore.Dsl do
  @moduledoc false

  defmodule Expirable do
    defstruct [:name, :fetch, :refresh, :scope, :keyed, :__spark_metadata__]
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
        type: {:or, [{:fun, 0}, {:fun, 1}]},
        required: true,
        doc:
          "Function that returns {:ok, value, expires_at} or :error. expires_at is Unix timestamp in milliseconds, or :infinity for values that never expire. Use a 1-arity function when keyed: true."
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
