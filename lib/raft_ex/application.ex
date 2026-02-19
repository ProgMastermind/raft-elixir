defmodule RaftEx.Application do
  @moduledoc """
  OTP Application entry point for RaftEx.

  Starts the supervision tree:
  - `RaftEx.Inspector`     — telemetry event handler (observability)
  - `RaftEx.NodeSupervisor` — DynamicSupervisor for Raft node processes

  Raft nodes are started at runtime via `RaftEx.start_node/2`, not here.
  This keeps the supervision tree minimal and lets nodes be added/removed
  dynamically without restarting the application.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RaftEx.TcpConnectionPool,

      # Telemetry-based event observer — must start before any Raft nodes
      # so that all state transitions and RPCs are captured from the start.
      RaftEx.Inspector,

      # DynamicSupervisor for Raft node processes.
      # Nodes are added via DynamicSupervisor.start_child/2 at runtime.
      {DynamicSupervisor, name: RaftEx.NodeSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_one, name: RaftEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
