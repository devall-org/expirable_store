defmodule ExpirableStore.Info do
  @moduledoc false

  use Spark.InfoGenerator, extension: ExpirableStore.Dsl, sections: [:expirables]
end
