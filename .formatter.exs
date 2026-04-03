# Used by "mix format"
spark_locals_without_parens = [
  expirable: 2,
  fetch: 1,
  refresh: 1,
  scope: 1,
  keyed: 1,
  require_initial_state: 1
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
