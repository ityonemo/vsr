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
      aliases: [
        tidewave: "run --no-halt -e 'Logger.configure(level: :debug); Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
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
          extra_applications: [:logger]
        ]
    end
  end

  def elixirc_paths(:test), do: ["lib", "test/_support", "maelstrom-adapter"]
  def elixirc_paths(:maelstrom), do: ["lib", "maelstrom-adapter", "test/_support"]
  def elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:protoss, "~> 1.1"},
      {:mox, "~> 1.0", only: :test},
      # MCP TOOLS
      {:tidewave, "~> 0.4", only: :dev},
      {:bandit, "~> 1.0", only: :dev},
    ]
  end
end
