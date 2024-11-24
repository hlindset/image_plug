defmodule Imagex.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :imagex,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:image, "~> 0.37"},
      {:req, "~> 0.5"},
      {:nimble_parsec, "~> 1.4.0"},
      {:bandit, "~> 1.0", only: [:test, :dev]},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:excoveralls, ">= 0.0.0", only: [:test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
