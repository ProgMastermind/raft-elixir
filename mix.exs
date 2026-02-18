defmodule RaftEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :raft_ex,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: """
      A complete, spec-compliant implementation of the Raft consensus algorithm
      in Elixir/OTP. Implements leader election, log replication, snapshots,
      and client interaction per Ongaro & Ousterhout (2014).
      """
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {RaftEx.Application, []}
    ]
  end

  defp deps do
    [
      # Observability — telemetry for emitting Raft state transition events
      {:telemetry, "~> 1.3"},

      # Property-based testing — StreamData for log invariant tests
      {:stream_data, "~> 1.1", only: [:test, :dev]},

      # Test coverage
      {:excoveralls, "~> 0.18", only: :test},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      # Run compile + credo + test in sequence
      ci: ["compile --warnings-as-errors", "credo --strict", "test"],
      # Quick check before committing
      check: ["compile --warnings-as-errors", "test"]
    ]
  end
end
