defmodule RaftEx do
  @moduledoc """
  RaftEx — A complete, spec-compliant Raft consensus algorithm in Elixir/OTP.

  Implements the Raft paper: "In Search of an Understandable Consensus Algorithm"
  by Ongaro & Ousterhout (2014).

  This module will expose the public API (start_node, set, get, delete) once
  the full implementation is complete. See individual modules for details:

  - `RaftEx.Persistence`  — §5.1 persistent state (currentTerm, votedFor)
  - `RaftEx.Log`          — §5.3 log storage and replication
  - `RaftEx.RPC`          — §5.2, §5.3, §7 message structs
  - `RaftEx.Cluster`      — §5.2, §5.3 quorum math
  - `RaftEx.StateMachine` — §5.3 KV state machine
  - `RaftEx.Snapshot`     — §7 log compaction
  - `RaftEx.Inspector`    — observability (telemetry)
  - `RaftEx.Server`       — §5.1–§5.6, §7, §8 Raft FSM (:gen_statem)
  """
end
