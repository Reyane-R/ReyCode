defmodule ReyCode.MixProject do
  use Mix.Project

  def project do
    [
      app: :rey_code,
      version: "0.1.3",
      licenses: ["MIT"],
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Coverage floor — ratchet upward as coverage improves, never down.
      test_coverage: [tool: ExCoveralls, summary: [threshold: 75]],
      deps: deps(),
      aliases: aliases(),
      releases: [rey_code: [include_executables_for: [:unix], steps: [:assemble, :tar]]],
      dialyzer: [plt_add_apps: [:mix, :credo]]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :runtime_tools, :ssl],
      mod: {ReyCode.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [check: :test, coverage: :test]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:breeze, "~> 0.5.0"},
      {:exqlite, "~> 0.39"},
      {:exile, "~> 0.14"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:excoveralls, "~> 0.18.5", only: :test},
      {:castore, "~> 1.0", only: :test}
    ]
  end

  defp elixirc_paths(:dev), do: ["lib", "credo_checks", "quality_tools"]
  defp elixirc_paths(:test), do: ["lib", "test/support", "credo_checks", "quality_tools"]
  defp elixirc_paths(_env), do: ["lib"]

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test"
      ],
      coverage: ["coveralls.multiple --type lcov --type local"]
    ]
  end
end
