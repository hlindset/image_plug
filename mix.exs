defmodule ImagePlug.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :image_plug,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: extra_compilers(Mix.env()) ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: [
        main: "ImagePlug",
        extras: [
          "README.md",
          "docs/imgproxy_path_api.md",
          "docs/transform_operations.md"
        ]
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {ImagePlug.Application, []},
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.html": :test]]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp extra_compilers(:prod), do: []
  defp extra_compilers(_env), do: [:boundary]

  defp deps do
    [
      {:plug, "~> 1.18"},
      {:nimble_options, "~> 1.1"},
      {:image, "~> 0.67"},
      {:color, "~> 0.13"},
      {:req, "~> 0.5"},
      {:bandit, "~> 1.0", only: [:test, :dev]},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:boundary, "~> 0.10", runtime: false},
      {:excoveralls, ">= 0.0.0", only: [:test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "demo.build": ["cmd pnpm run demo:build"],
      "demo.check": ["cmd pnpm run demo:check"],
      "demo.dev": ["cmd pnpm run demo:dev"],
      "demo.format": ["cmd pnpm run demo:format"],
      "demo.format.check": ["cmd pnpm run demo:format:check"],
      "demo.lint": ["cmd pnpm run demo:lint"],
      "demo.test": ["cmd pnpm run demo:test"],
      "demo.verify": ["demo.test", "demo.check", "demo.format.check", "demo.lint", "demo.build"],
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
