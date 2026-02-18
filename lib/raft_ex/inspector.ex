defmodule RaftEx.Inspector do
  @moduledoc """
  Telemetry-based observability for RaftEx. (§5.1–§5.6, §7, §8)

  Attaches handlers to all `:raft_ex` telemetry events and prints
  colored, structured output to stdout so every state transition, RPC,
  commit, and snapshot is visible during the demo.

  ## Events handled

  | Event | Description |
  |-------|-------------|
  | `[:raft_ex, :state, :transition]` | Role change (follower/candidate/leader) |
  | `[:raft_ex, :election, :start]`   | Candidate starts election |
  | `[:raft_ex, :election, :won]`     | Candidate wins election |
  | `[:raft_ex, :election, :lost]`    | Candidate loses (higher term seen) |
  | `[:raft_ex, :vote, :granted]`     | Follower grants vote |
  | `[:raft_ex, :vote, :denied]`      | Follower denies vote |
  | `[:raft_ex, :rpc, :sent]`         | RPC sent to peer |
  | `[:raft_ex, :rpc, :reply_sent]`   | RPC reply sent to peer |
  | `[:raft_ex, :log, :appended]`     | Leader appended entry to log |
  | `[:raft_ex, :log, :committed]`    | Entry committed (majority replicated) |
  | `[:raft_ex, :log, :applied]`      | Entry applied to state machine |
  | `[:raft_ex, :snapshot, :created]` | Snapshot created (log compaction) |
  | `[:raft_ex, :snapshot, :installed]`| Snapshot installed on follower |
  | `[:raft_ex, :heartbeat, :sent]`   | Leader sent heartbeat |
  """

  use GenServer
  require Logger

  # ANSI color codes for role-based coloring
  @reset "\e[0m"
  @bold "\e[1m"
  @cyan "\e[36m"
  @yellow "\e[33m"
  @green "\e[32m"
  @red "\e[31m"
  @magenta "\e[35m"
  @blue "\e[34m"
  @white "\e[37m"

  @events [
    [:raft_ex, :state, :transition],
    [:raft_ex, :election, :start],
    [:raft_ex, :election, :won],
    [:raft_ex, :election, :lost],
    [:raft_ex, :vote, :granted],
    [:raft_ex, :vote, :denied],
    [:raft_ex, :rpc, :sent],
    [:raft_ex, :rpc, :reply_sent],
    [:raft_ex, :log, :appended],
    [:raft_ex, :log, :committed],
    [:raft_ex, :log, :applied],
    [:raft_ex, :snapshot, :created],
    [:raft_ex, :snapshot, :installed],
    [:raft_ex, :heartbeat, :sent]
  ]

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    :telemetry.attach_many(
      "raft_ex_inspector",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :telemetry.detach("raft_ex_inspector")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Telemetry event handlers
  # ---------------------------------------------------------------------------

  @doc false
  def handle_event([:raft_ex, :state, :transition], _measurements, meta, _config) do
    color = role_color(meta[:role])
    node = format_node(meta[:node_id])
    role = String.upcase(to_string(meta[:role]))
    from = meta[:from_role]
    term = meta[:term]

    IO.puts(
      "#{color}#{bold()}#{node} [#{role}]#{reset()} term=#{term} | #{from} → #{meta[:role]}"
    )
  end

  def handle_event([:raft_ex, :election, :start], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    term = meta[:term]
    IO.puts("#{yellow()}#{node} [CANDIDATE] ⏰ election timeout → starting election term=#{term}#{reset()}")
  end

  def handle_event([:raft_ex, :election, :won], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    term = meta[:term]
    votes = meta[:votes]
    IO.puts("#{green()}#{bold()}#{node} [LEADER] 🏆 WON election! term=#{term}, votes=#{votes}#{reset()}")
  end

  def handle_event([:raft_ex, :election, :lost], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    term = meta[:term]
    IO.puts("#{red()}#{node} [FOLLOWER] ❌ lost election (higher term=#{term} seen)#{reset()}")
  end

  def handle_event([:raft_ex, :vote, :granted], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    candidate = meta[:candidate_id]
    term = meta[:term]
    IO.puts("#{cyan()}#{node} [FOLLOWER] ✅ granted vote to #{candidate} for term=#{term}#{reset()}")
  end

  def handle_event([:raft_ex, :vote, :denied], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    candidate = meta[:candidate_id]
    reason = meta[:reason]
    IO.puts("#{white()}#{node} [FOLLOWER] ⛔ denied vote to #{candidate} (#{reason})#{reset()}")
  end

  def handle_event([:raft_ex, :rpc, :sent], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    to = meta[:to]
    rpc = meta[:rpc]
    IO.puts("#{blue()}#{node} → SEND #{rpc} to #{to}#{reset()}")
  end

  def handle_event([:raft_ex, :rpc, :reply_sent], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    to = meta[:to]
    rpc = meta[:rpc]
    IO.puts("#{blue()}#{node} ← REPLY #{rpc} to #{to}#{reset()}")
  end

  def handle_event([:raft_ex, :log, :appended], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    index = meta[:index]
    term = meta[:term]
    cmd = inspect(meta[:command])
    IO.puts("#{magenta()}#{node} [LEADER] 📝 appended index=#{index} term=#{term} cmd=#{cmd}#{reset()}")
  end

  def handle_event([:raft_ex, :log, :committed], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    index = meta[:commit_index]
    IO.puts("#{green()}#{bold()}#{node} ✔ COMMITTED up to index=#{index}#{reset()}")
  end

  def handle_event([:raft_ex, :log, :applied], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    index = meta[:index]
    result = inspect(meta[:result])
    IO.puts("#{green()}#{node} ⚙ APPLIED index=#{index} result=#{result}#{reset()}")
  end

  def handle_event([:raft_ex, :snapshot, :created], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    idx = meta[:last_included_index]
    term = meta[:last_included_term]
    IO.puts("#{magenta()}#{node} 📸 SNAPSHOT created last_index=#{idx} last_term=#{term}#{reset()}")
  end

  def handle_event([:raft_ex, :snapshot, :installed], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    idx = meta[:last_included_index]
    term = meta[:last_included_term]
    IO.puts("#{magenta()}#{node} 📥 SNAPSHOT installed last_index=#{idx} last_term=#{term}#{reset()}")
  end

  def handle_event([:raft_ex, :heartbeat, :sent], _measurements, meta, _config) do
    node = format_node(meta[:node_id])
    to = meta[:to]
    IO.puts("#{white()}#{node} [LEADER] 💓 heartbeat → #{to}#{reset()}")
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp format_node(node_id), do: "[NODE #{inspect(node_id)}]"

  defp role_color(:follower), do: @cyan
  defp role_color(:candidate), do: @yellow
  defp role_color(:leader), do: @green
  defp role_color(_), do: @white

  defp bold(), do: @bold
  defp reset(), do: @reset
  defp yellow(), do: @yellow
  defp green(), do: @green
  defp red(), do: @red
  defp cyan(), do: @cyan
  defp magenta(), do: @magenta
  defp blue(), do: @blue
  defp white(), do: @white
end
