defmodule RaftEx.Inspector do
  @moduledoc """
  Telemetry-based event observer for RaftEx.

  Subscribes to all Raft telemetry events and prints human-readable,
  color-coded output to stdout so the full data flow is visible during
  development and demos.

  Log format: `[NODE :id] [ROLE] event description`

  This module is a GenServer that attaches telemetry handlers on start.
  It is started by `RaftEx.Application` before any Raft nodes, ensuring
  every state transition and RPC is captured from the very beginning.

  ## Telemetry Events Handled

  - `[:raft_ex, :state_transition]`  — role change (follower/candidate/leader)
  - `[:raft_ex, :rpc, :sent]`        — RPC sent to a peer
  - `[:raft_ex, :rpc, :reply_sent]`  — RPC reply sent back to sender
  - `[:raft_ex, :rpc, :received]`    — RPC received from a peer
  - `[:raft_ex, :election, :timeout]`— election timeout fired
  - `[:raft_ex, :election, :won]`    — candidate won election
  - `[:raft_ex, :election, :lost]`   — candidate lost (stepped down)
  - `[:raft_ex, :log, :appended]`    — entry appended to local log
  - `[:raft_ex, :log, :committed]`   — commitIndex advanced
  - `[:raft_ex, :log, :applied]`     — entry applied to state machine
  - `[:raft_ex, :snapshot, :created]`   — snapshot taken
  - `[:raft_ex, :snapshot, :installed]` — snapshot installed from leader
  - `[:raft_ex, :client, :command]`  — client command received
  - `[:raft_ex, :client, :response]` — client command response sent
  """

  use GenServer
  require Logger

  # All telemetry events this inspector handles
  @telemetry_events [
    [:raft_ex, :state_transition],
    [:raft_ex, :rpc, :sent],
    [:raft_ex, :rpc, :reply_sent],
    [:raft_ex, :rpc, :received],
    [:raft_ex, :election, :timeout],
    [:raft_ex, :election, :won],
    [:raft_ex, :election, :lost],
    [:raft_ex, :log, :appended],
    [:raft_ex, :log, :committed],
    [:raft_ex, :log, :applied],
    [:raft_ex, :snapshot, :created],
    [:raft_ex, :snapshot, :installed],
    [:raft_ex, :client, :command],
    [:raft_ex, :client, :response]
  ]

  # ANSI color codes
  @reset "\e[0m"
  @bold "\e[1m"
  @cyan "\e[36m"
  @green "\e[32m"
  @yellow "\e[33m"
  @red "\e[31m"
  @magenta "\e[35m"
  @blue "\e[34m"
  @white "\e[37m"

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Attach all telemetry handlers
    for event <- @telemetry_events do
      handler_id = {__MODULE__, event}

      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_event/4,
        nil
      )
    end

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    # Detach all handlers on shutdown
    for event <- @telemetry_events do
      :telemetry.detach({__MODULE__, event})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Telemetry event handlers
  # ---------------------------------------------------------------------------

  @doc false
  def handle_event([:raft_ex, :state_transition], _measurements, meta, _config) do
    %{node_id: node_id, from: from, to: to, term: term} = meta
    color = role_color(to)

    IO.puts(
      "#{@bold}#{color}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(to))}]#{@reset} " <>
        "#{@white}term=#{term} | #{from} → #{to}#{@reset}"
    )
  end

  def handle_event([:raft_ex, :rpc, :sent], _measurements, meta, _config) do
    %{node_id: node_id, to: to, rpc: rpc_type} = meta
    role = Map.get(meta, :role, :unknown)

    IO.puts(
      "#{@cyan}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(role))}]#{@reset} " <>
        "→ SEND #{rpc_type} to #{inspect(to)}"
    )
  end

  def handle_event([:raft_ex, :rpc, :reply_sent], _measurements, meta, _config) do
    %{node_id: node_id, to: to, rpc: rpc_type} = meta
    role = Map.get(meta, :role, :unknown)

    IO.puts(
      "#{@blue}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(role))}]#{@reset} " <>
        "← REPLY #{rpc_type} to #{inspect(to)}"
    )
  end

  def handle_event([:raft_ex, :rpc, :received], _measurements, meta, _config) do
    %{node_id: node_id, from: from, rpc: rpc_type} = meta
    role = Map.get(meta, :role, :unknown)

    IO.puts(
      "#{@white}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(role))}]#{@reset} " <>
        "← RECV #{rpc_type} from #{inspect(from)}"
    )
  end

  def handle_event([:raft_ex, :election, :timeout], _measurements, meta, _config) do
    %{node_id: node_id, term: term} = meta

    IO.puts(
      "#{@yellow}[NODE #{inspect(node_id)}] [FOLLOWER]#{@reset} " <>
        "⏰ election timeout fired, starting election for term #{term + 1}"
    )
  end

  def handle_event([:raft_ex, :election, :won], _measurements, meta, _config) do
    %{node_id: node_id, term: term, votes: votes} = meta

    IO.puts(
      "#{@bold}#{@green}[NODE #{inspect(node_id)}] [LEADER]#{@reset} " <>
        "🏆 WON election! term=#{term}, votes=#{votes}"
    )
  end

  def handle_event([:raft_ex, :election, :lost], _measurements, meta, _config) do
    %{node_id: node_id, term: term} = meta

    IO.puts(
      "#{@red}[NODE #{inspect(node_id)}] [CANDIDATE]#{@reset} " <>
        "✗ lost election, stepping down. term=#{term}"
    )
  end

  def handle_event([:raft_ex, :log, :appended], _measurements, meta, _config) do
    %{node_id: node_id, index: index, term: term} = meta
    role = Map.get(meta, :role, :leader)

    IO.puts(
      "#{@magenta}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(role))}]#{@reset} " <>
        "📝 log appended index=#{index} term=#{term}"
    )
  end

  def handle_event([:raft_ex, :log, :committed], _measurements, meta, _config) do
    %{node_id: node_id, commit_index: commit_index} = meta
    role = Map.get(meta, :role, :leader)

    IO.puts(
      "#{@green}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(role))}]#{@reset} " <>
        "✓ committed up to index=#{commit_index}"
    )
  end

  def handle_event([:raft_ex, :log, :applied], _measurements, meta, _config) do
    %{node_id: node_id, index: index, command: command} = meta
    role = Map.get(meta, :role, :unknown)

    IO.puts(
      "#{@green}[NODE #{inspect(node_id)}] [#{String.upcase(to_string(role))}]#{@reset} " <>
        "⚙  applied index=#{index} cmd=#{inspect(command)}"
    )
  end

  def handle_event([:raft_ex, :snapshot, :created], _measurements, meta, _config) do
    %{node_id: node_id, last_included_index: idx, last_included_term: term} = meta

    IO.puts(
      "#{@yellow}[NODE #{inspect(node_id)}] [LEADER]#{@reset} " <>
        "📸 snapshot created last_index=#{idx} last_term=#{term}"
    )
  end

  def handle_event([:raft_ex, :snapshot, :installed], _measurements, meta, _config) do
    %{node_id: node_id, last_included_index: idx} = meta

    IO.puts(
      "#{@yellow}[NODE #{inspect(node_id)}] [FOLLOWER]#{@reset} " <>
        "📥 snapshot installed last_index=#{idx}"
    )
  end

  def handle_event([:raft_ex, :client, :command], _measurements, meta, _config) do
    %{node_id: node_id, command: command} = meta

    IO.puts(
      "#{@white}[NODE #{inspect(node_id)}] [CLIENT]#{@reset} " <>
        "→ command #{inspect(command)}"
    )
  end

  def handle_event([:raft_ex, :client, :response], _measurements, meta, _config) do
    %{node_id: node_id, result: result} = meta

    IO.puts(
      "#{@white}[NODE #{inspect(node_id)}] [CLIENT]#{@reset} " <>
        "← response #{inspect(result)}"
    )
  end

  # Catch-all for any unhandled events
  def handle_event(event, _measurements, _meta, _config) do
    Logger.debug("RaftEx.Inspector: unhandled event #{inspect(event)}")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp role_color(:leader), do: @green
  defp role_color(:candidate), do: @yellow
  defp role_color(:follower), do: @cyan
  defp role_color(_), do: @white
end
