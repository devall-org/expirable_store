defmodule ExpirableStore.Info do
  use Spark.InfoGenerator, extension: ExpirableStore.Dsl, sections: [:expirables]
end
