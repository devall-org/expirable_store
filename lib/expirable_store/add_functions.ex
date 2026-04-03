defmodule ExpirableStore.AddFunctions do
  @moduledoc false

  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    generic_fns =
      quote do
        def fetch(name), do: ExpirableStore.fetch(__MODULE__, name)
        def fetch!(name), do: ExpirableStore.fetch!(__MODULE__, name)
        def fetch(name, key), do: ExpirableStore.fetch(__MODULE__, name, key)
        def fetch!(name, key), do: ExpirableStore.fetch!(__MODULE__, name, key)
        def set_state(name, state), do: ExpirableStore.set_state(__MODULE__, name, state)
        def set_state(name, key, state), do: ExpirableStore.set_state(__MODULE__, name, key, state)
        def clear(name), do: ExpirableStore.clear(__MODULE__, name)
        def clear(name, key), do: ExpirableStore.clear(__MODULE__, name, key)
        def clear_all(), do: ExpirableStore.clear_all(__MODULE__)
      end

    {:ok,
     dsl_state
     |> Spark.Dsl.Transformer.eval([], [generic_fns])}
  end
end
