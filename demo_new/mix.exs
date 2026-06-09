defmodule ImagePipeDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :image_pipe_demo,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      usage_rules: usage_rules(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:hologram],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ImagePipeDemo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["app", "lib", "test/support"]
  defp elixirc_paths(_), do: ["app", "lib"]

  # `usage_rules` config. Instead of inlining dependency usage rules into a big
  # CLAUDE.md/AGENTS.md, we generate on-demand agent skills under .claude/skills/.
  # Run `mix usage_rules.sync` after changing this; the config is the source of
  # truth (skills present on disk but absent here are removed on each sync).
  defp usage_rules do
    [
      skills: [
        # Generate into the repo-root .claude/skills (one level up from this demo
        # project) so the skill is discoverable when Claude Code is launched from
        # the repo root. Stays correct after the demo_new -> demo rename, since
        # ".." remains the repo root either way.
        location: "../.claude/skills",
        build: [
          hologram: [
            description:
              "Use when working with Hologram in this demo: pages, components, " <>
                "layouts, ~HOLO templates, actions/commands, routing, and the " <>
                "client runtime. Hologram is NOT Phoenix LiveView; consult before " <>
                "writing any Hologram code.",
            usage_rules: [:hologram]
          ]
        ]
      ]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:hologram, "~> 0.9"},
      # The plug library under test. This demo is a dev/test harness for it;
      # the dependency direction is one-way (demo -> library).
      {:image_pipe, path: ".."}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind image_pipe_demo", "esbuild image_pipe_demo"],
      "assets.deploy": [
        "tailwind image_pipe_demo --minify",
        "esbuild image_pipe_demo --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
