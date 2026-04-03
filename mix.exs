defmodule ExpirableStore.MixProject do
  use Mix.Project

  @version "0.7.0"
  @source_url "https://github.com/devall-org/expirable_store"

  def project do
    [
      app: :expirable_store,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Lightweight expirable value store for Elixir with cluster-wide or local scoping",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: ["test.all": :test]
    ]
  end

  defp aliases do
    [
      "test.all": "cmd elixir --sname test_runner -S mix test --include distributed"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExpirableStore.Application, []}
    ]
  end

  defp deps do
    [
      {:spark, "~> 2.0"},
      {:sourceror, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
