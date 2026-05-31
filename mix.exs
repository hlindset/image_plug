defmodule ImagePipe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hlindset/image_pipe"

  def project do
    [
      app: :image_pipe,
      version: @version,
      description: description(),
      package: package(),
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: extra_compilers(Mix.env()) ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        source_url: @source_url,
        assets: %{"docs/assets" => "docs/assets"},
        extras: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE.md",
          "docs/cache.md",
          "docs/operational_notes.md",
          "docs/telemetry.md",
          "docs/imgproxy_path_api.md",
          "docs/imgproxy_support_matrix.md",
          "docs/transform_operations.md"
        ],
        groups_for_modules: [
          "Package API": [ImagePipe],
          "Plug API": [ImagePipe.Plug],
          "Parser API": [ImagePipe.Parser, ~r/ImagePipe\.Parser\..*/],
          "Plan Model": [ImagePipe.Plan, ~r/ImagePipe\.Plan\..*/],
          "Transform API": [ImagePipe.Transform, ~r/ImagePipe\.Transform\..*/],
          "Cache API": [ImagePipe.Cache, ~r/ImagePipe\.Cache\..*/],
          "Runtime Internals": [
            ~r/ImagePipe\.Source.*/,
            ~r/ImagePipe\.Output.*/,
            ~r/ImagePipe\.Request.*/,
            ~r/ImagePipe\.Response.*/,
            ImagePipe.Telemetry
          ]
        ]
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {ImagePipe.Application, []},
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

  defp description do
    "A Plug-based image optimization server with an imgproxy-compatible path parser."
  end

  defp package do
    [
      files: [
        "lib",
        "priv",
        "docs/cache.md",
        "docs/assets/demo-fiddle-desktop.png",
        "docs/imgproxy_path_api.md",
        "docs/imgproxy_support_matrix.md",
        "docs/operational_notes.md",
        "docs/telemetry.md",
        "docs/transform_operations.md",
        "mix.exs",
        "README.md",
        "LICENSE.md",
        "CHANGELOG.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Håvard Lindset"]
    ]
  end

  defp deps do
    base = [
      {:plug, "~> 1.18"},
      {:telemetry, "~> 1.0"},
      {:nimble_options, "~> 1.1"},
      {:image, "~> 0.67"},
      {:vix,
       git: "https://github.com/hlindset/vix.git",
       ref: "3a30758d44526d3c914b2076bd0be201c972f2b7",
       override: true},
      {:color, "~> 0.13"},
      {:req, "~> 0.5"},
      {:bandit, "~> 1.0", only: [:test, :dev]},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:boundary, "~> 0.10", runtime: false},
      {:excoveralls, ">= 0.0.0", only: [:test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:talan, "~> 0.2.1"}
    ]

    # Real face detection needs `image_vision` AND its optional ONNX backend
    # `ortex` (a Rust/ONNX runtime): `image_vision`'s `Image.FaceDetection` is
    # compiled only when Ortex is configured (`if ImageVision.ortex_configured?()`),
    # and the YuNet model (~340 KB) downloads on first use.
    #
    # This closure (Rust toolchain + model) is enabled in `:dev` so the demo
    # server (`mix image_pipe.server`) can exercise `g:obj:face` and face-assist
    # for real. It must NOT burden the default test/CI lane, so it reaches `:test`
    # only via the opt-in `IMAGE_VISION=1` flag, which the real-dependency detector
    # test relies on (`IMAGE_VISION=1 mix test --only image_vision`).
    ml_envs = if System.get_env("IMAGE_VISION") in ["1", "true"], do: [:dev, :test], else: [:dev]

    base ++
      [
        {:image_vision, "~> 0.4", only: ml_envs},
        {:ortex, "~> 0.1", only: ml_envs}
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
      "demo.setup": ["cmd pnpm install --frozen-lockfile"],
      "demo.test": ["cmd pnpm run demo:test"],
      "demo.verify": ["demo.test", "demo.check", "demo.format.check", "demo.lint", "demo.build"],
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
