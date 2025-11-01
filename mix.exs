defmodule Vsr.MixProject do
  use Mix.Project

  def project do
    [
      app: :vsr,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: elixirc_options(Mix.env()),
      aliases: [
        mcps:
          "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000); Bandit.start_link(plug: Codicil.Plug, port: 4700) end)'",
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    case Mix.env() do
      :maelstrom ->
        [
          extra_applications: [:logger, :sasl],
          mod: {Maelstrom.Application, []}
        ]

      _ ->
        [
          extra_applications: [:logger, :runtime_tools]
        ]
    end
  end

  def elixirc_paths(:test), do: ["lib", "test/_support", "maelstrom-adapter"]
  def elixirc_paths(:maelstrom), do: ["lib", "maelstrom-adapter", "test/_support"]
  def elixirc_paths(_), do: ["lib"]

  defp elixirc_options(_env), do: []

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:protoss, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      {:mox, "~> 1.0", only: :test},
      # MCP TOOLS
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: [:dev, :test]},
      {:codicil, path: "../codicil", only: [:dev, :test]}, # "~> 0.2", only: [:dev, :test]}
    ]
  end
end
