defmodule RaftEx.Server do
  @moduledoc """
  Raft consensus FSM — follower, candidate, leader. (§5.1–§5.6, §7, §8)

  Implements the complete Raft algorithm using :gen_statem with
  state_functions callback mode. Each role is a named function:
  follower/3, candidate/3, leader/3.

  ## Persistent state (§5.1) — written to DETS before any RPC response
  - currentTerm  — latest term seen
  - votedFor     — candidateId voted for in current term (nil if none)
  - log          — log entries (index, term, command)

  ## Volatile state (§5.1)
  - commitIndex  — highest log index known to be committed (init 0)
  - lastApplied  — highest log index applied to state machine (init 0)

  ## Leader volatile state (§5.1, reinit after election)
  - nextIndex    — for each peer, next log index to send (init lastIndex+1)
  - matchIndex   — for each peer, highest index known replicated (init 0)

  ## Timing (§5.2, §5.6)
  - Election timeout: 150–300ms random
  - Heartbeat interval: 50ms
  """

  @behaviour :gen_statem

  require Logger

  alias RaftEx.{Cluster, Log, Persistence, RPC, Snapshot, StateMachine}
  alias RaftEx.RPC.{AppendEntries, AppendEntriesReply, RequestVote, RequestVoteReply,
                    InstallSnapshot, InstallSnapshotReply}

  # §5.2, §5.6 — timing constants
  @election_timeout_min 150
  @election_timeout_max 300
  @heartbeat_interval   50

  # ---------------------------------------------------------------------------
  # Data struct — all server state in one place
  # ---------------------------------------------------------------------------

  defstruct [
    :node_id,       # atom — this server's identity
    :cluster,       # [atom] — all node ids including self
    :current_term,  # non_neg_integer — §5.1 persistent
    :voted_for,     # atom | nil — §5.1 persistent
    :commit_index,  # non_neg_integer — §5.1 volatile (init 0)
    :last_applied,  # non_neg_integer — §5.1 volatile (init 0)
    :sm_state,      # map — state machine state
    :leader_id,     # atom | nil — current known leader (for client redirect §8)
    # Candidate state
    :votes_received,# MapSet of node_ids that voted for us
    # Leader state (reinitialized after election)
    :next_index,    # %{peer => index} — §5.3
    :match_index,   # %{peer => index} — §5.3
    # Pending client calls waiting for commit
    :pending        # %{log_index => {from, command}}
  ]

  # ---------------------------------------------------------------------------
  # Public API — start a Raft node
  # ---------------------------------------------------------------------------

  @doc """
  child_spec/1 for DynamicSupervisor compatibility.
  Accepts `{node_id, cluster}` as the argument.
  """
  def child_spec({node_id, cluster}) do
    %{
      id: {__MODULE__, node_id},
      start: {__MODULE__, :start_link, [node_id, cluster]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @doc """
  Start a Raft server node and register it under `raft_server_{node_id}`.
  """
  @spec start_link(atom(), [atom()]) :: :gen_statem.start_ret()
  def start_link(node_id, cluster) do
    :gen_statem.start_link(
      {:local, server_name(node_id)},
      __MODULE__,
      {node_id, cluster},
      []
    )
  end

  @doc """
  Submit a command to the cluster. Blocks until committed. (§8)
  Routes to the leader; returns {:error, {:redirect, leader_id}} if not leader.
  """
  @spec command(atom(), term()) :: {:ok, term()} | {:error, term()}
  def command(node_id, cmd) do
    :gen_statem.call(server_name(node_id), {:command, cmd}, 5_000)
  end

  @doc """
  Return the current state of this node (for debugging/demo).
  """
  @spec status(atom()) :: map()
  def status(node_id) do
    :gen_statem.call(server_name(node_id), :status, 1_000)
  end

  # ---------------------------------------------------------------------------
  # :gen_statem callbacks
  # ---------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode(), do: :state_functions

  @impl :gen_statem
  def init({node_id, cluster}) do
    # §5.1: open persistent storage
    {:ok, _} = Persistence.open(node_id)
    {:ok, _} = Log.open(node_id)

    # §5.1: recover persistent state from stable storage
    {current_term, voted_for} = Persistence.load_all(node_id)

    # §7: restore snapshot if one exists
    {sm_state, commit_index, last_applied} =
      case Snapshot.load(node_id) do
        nil ->
          {StateMachine.new(), 0, 0}
        snap ->
          sm = StateMachine.deserialize(snap.data)
          idx = snap.last_included_index
          {sm, idx, idx}
      end

    data = %__MODULE__{
      node_id: node_id,
      cluster: cluster,
      current_term: current_term,
      voted_for: voted_for,
      commit_index: commit_index,
      last_applied: last_applied,
      sm_state: sm_state,
      leader_id: nil,
      votes_received: MapSet.new(),
      next_index: %{},
      match_index: %{},
      pending: %{}
    }

    :telemetry.execute([:raft_ex, :state, :transition], %{count: 1},
      %{node_id: node_id, role: :follower, from_role: :init, term: current_term})

    # §5.2: start as follower with random election timeout
    {:ok, :follower, data, [{:state_timeout, election_timeout(), :election_timeout}]}
  end

  # ---------------------------------------------------------------------------
  # FOLLOWER state (§5.2)
  # ---------------------------------------------------------------------------

  def follower(:state_timeout, :election_timeout, data) do
    # §5.2: election timeout fires — convert to candidate
    start_election(data)
  end

  # AppendEntries from leader (§5.3)
  def follower(:cast, %AppendEntries{} = rpc, data) do
    handle_append_entries(rpc, data, :follower)
  end

  # RequestVote from candidate (§5.2)
  def follower(:cast, %RequestVote{} = rpc, data) do
    handle_request_vote(rpc, data, :follower)
  end

  # InstallSnapshot from leader (§7)
  def follower(:cast, %InstallSnapshot{} = rpc, data) do
    handle_install_snapshot(rpc, data)
  end

  # Stale replies — ignore
  def follower(:cast, %AppendEntriesReply{}, data) do
    {:keep_state, data}
  end
  def follower(:cast, %RequestVoteReply{}, data) do
    {:keep_state, data}
  end
  def follower(:cast, %InstallSnapshotReply{}, data) do
    {:keep_state, data}
  end

  # Client command — redirect to leader (§8)
  def follower({:call, from}, {:command, _cmd}, data) do
    {:keep_state, data, [{:reply, from, {:error, {:redirect, data.leader_id}}}]}
  end

  def follower({:call, from}, :status, data) do
    {:keep_state, data, [{:reply, from, build_status(data, :follower)}]}
  end

  # ---------------------------------------------------------------------------
  # CANDIDATE state (§5.2)
  # ---------------------------------------------------------------------------

  def candidate(:state_timeout, :election_timeout, data) do
    # §5.2: split vote — restart election with new term
    start_election(data)
  end

  # RequestVoteReply — count votes (§5.2)
  def candidate(:cast, %RequestVoteReply{} = reply, data) do
    handle_vote_reply(reply, data)
  end

  # AppendEntries from a new leader — step down (§5.2)
  def candidate(:cast, %AppendEntries{} = rpc, data) do
    # §5.2: if we receive AppendEntries from a valid leader, revert to follower
    if rpc.term >= data.current_term do
      data = maybe_update_term(data, rpc.term)
      handle_append_entries(rpc, data, :candidate)
    else
      # stale — ignore
      {:keep_state, data}
    end
  end

  def candidate(:cast, %RequestVote{} = rpc, data) do
    handle_request_vote(rpc, data, :candidate)
  end

  def candidate(:cast, %InstallSnapshot{} = rpc, data) do
    handle_install_snapshot(rpc, data)
  end

  def candidate(:cast, %AppendEntriesReply{}, data), do: {:keep_state, data}
  def candidate(:cast, %InstallSnapshotReply{}, data), do: {:keep_state, data}

  def candidate({:call, from}, {:command, _cmd}, data) do
    {:keep_state, data, [{:reply, from, {:error, {:redirect, data.leader_id}}}]}
  end

  def candidate({:call, from}, :status, data) do
    {:keep_state, data, [{:reply, from, build_status(data, :candidate)}]}
  end

  # ---------------------------------------------------------------------------
  # LEADER state (§5.3, §5.4, §8)
  # ---------------------------------------------------------------------------

  # Heartbeat timer fires — send AppendEntries to all peers (§5.2)
  def leader(:timeout, :heartbeat, data) do
    send_heartbeats(data)
  end

  # Client command — append to log and replicate (§5.3, §8)
  def leader({:call, from}, {:command, cmd}, data) do
    handle_client_command(from, cmd, data)
  end

  # AppendEntriesReply from follower (§5.3)
  def leader(:cast, %AppendEntriesReply{} = reply, data) do
    handle_append_entries_reply(reply, data)
  end

  # InstallSnapshotReply from follower (§7)
  def leader(:cast, %InstallSnapshotReply{} = reply, data) do
    handle_install_snapshot_reply(reply, data)
  end

  # AppendEntries from another leader — step down if higher term (§5.1)
  def leader(:cast, %AppendEntries{} = rpc, data) do
    if rpc.term > data.current_term do
      data = maybe_update_term(data, rpc.term)
      handle_append_entries(rpc, data, :leader)
    else
      # We are the leader — ignore stale AppendEntries
      {:keep_state, data}
    end
  end

  def leader(:cast, %RequestVote{} = rpc, data) do
    handle_request_vote(rpc, data, :leader)
  end

  def leader(:cast, %RequestVoteReply{}, data), do: {:keep_state, data}
  def leader(:cast, %InstallSnapshot{}, data), do: {:keep_state, data}

  def leader({:call, from}, :status, data) do
    {:keep_state, data, [{:reply, from, build_status(data, :leader)}]}
  end

  # Catch-all for leader
  def leader(event_type, event, data) do
    Logger.warning("[#{data.node_id}] leader: unhandled #{inspect(event_type)} #{inspect(event)}")
    {:keep_state, data}
  end

  # ---------------------------------------------------------------------------
  # Election helpers (§5.2, §5.4)
  # ---------------------------------------------------------------------------

  defp start_election(data) do
    # §5.2: increment currentTerm, vote for self, reset election timer
    new_term = data.current_term + 1

    # §5.1: persist BEFORE sending RPCs
    :ok = Persistence.save_term(data.node_id, new_term)
    :ok = Persistence.save_vote(data.node_id, data.node_id)

    data = %{data |
      current_term: new_term,
      voted_for: data.node_id,
      votes_received: MapSet.new([data.node_id]),
      leader_id: nil
    }

    :telemetry.execute([:raft_ex, :election, :start], %{count: 1},
      %{node_id: data.node_id, term: new_term})

    :telemetry.execute([:raft_ex, :state, :transition], %{count: 1},
      %{node_id: data.node_id, role: :candidate, from_role: :follower, term: new_term})

    # §5.2: send RequestVote to all peers
    last_log_index = Log.last_index(data.node_id)
    last_log_term  = Log.last_term(data.node_id)

    rpc = %RequestVote{
      term: new_term,
      candidate_id: data.node_id,
      last_log_index: last_log_index,
      last_log_term: last_log_term
    }

    for peer <- Cluster.peers(data.cluster, data.node_id) do
      RPC.send_rpc(data.node_id, peer, rpc)
    end

    # §5.2: check if single-node cluster (immediate win)
    cluster_size = Cluster.size(data.cluster)
    if Cluster.has_majority?(MapSet.size(data.votes_received), cluster_size) do
      become_leader(data)
    else
      {:next_state, :candidate, data,
       [{:state_timeout, election_timeout(), :election_timeout}]}
    end
  end

  defp handle_vote_reply(%RequestVoteReply{} = reply, data) do
    # §5.1: if reply has higher term, revert to follower
    if reply.term > data.current_term do
      data = step_down(data, reply.term)
      {:next_state, :follower, data,
       [{:state_timeout, election_timeout(), :election_timeout}]}
    else
      if reply.vote_granted and reply.term == data.current_term do
        votes = MapSet.put(data.votes_received, reply.from)
        data = %{data | votes_received: votes}
        cluster_size = Cluster.size(data.cluster)

        if Cluster.has_majority?(MapSet.size(votes), cluster_size) do
          become_leader(data)
        else
          {:keep_state, data}
        end
      else
        {:keep_state, data}
      end
    end
  end

  defp become_leader(data) do
    # §5.3: reinitialize nextIndex and matchIndex after election
    last_index = Log.last_index(data.node_id)
    peers = Cluster.peers(data.cluster, data.node_id)

    next_index  = Map.new(peers, fn p -> {p, last_index + 1} end)
    match_index = Map.new(peers, fn p -> {p, 0} end)

    data = %{data |
      next_index: next_index,
      match_index: match_index,
      leader_id: data.node_id,
      votes_received: MapSet.new()
    }

    :telemetry.execute([:raft_ex, :election, :won], %{count: 1},
      %{node_id: data.node_id, term: data.current_term,
        votes: MapSet.size(data.votes_received) + 1})

    :telemetry.execute([:raft_ex, :state, :transition], %{count: 1},
      %{node_id: data.node_id, role: :leader, from_role: :candidate,
        term: data.current_term})

    # §8: append no-op to commit entries from previous terms
    {:ok, noop_index} = Log.append(data.node_id, data.current_term, {:noop})

    :telemetry.execute([:raft_ex, :log, :appended], %{count: 1},
      %{node_id: data.node_id, index: noop_index, term: data.current_term, command: :noop})

    # Send initial heartbeats immediately
    data = do_send_heartbeats(data)

    {:next_state, :leader, data,
     [{:timeout, @heartbeat_interval, :heartbeat}]}
  end

  # ---------------------------------------------------------------------------
  # RequestVote handler — used by all roles (§5.2, §5.4.1)
  # ---------------------------------------------------------------------------

  defp handle_request_vote(%RequestVote{} = rpc, data, current_role) do
    # §5.1: if RPC term > currentTerm, update term and revert to follower
    data = if rpc.term > data.current_term, do: step_down(data, rpc.term), else: data

    grant? = can_grant_vote?(rpc, data)

    if grant? do
      # §5.1: persist vote BEFORE sending reply
      :ok = Persistence.save_vote(data.node_id, rpc.candidate_id)
      data = %{data | voted_for: rpc.candidate_id}

      :telemetry.execute([:raft_ex, :vote, :granted], %{count: 1},
        %{node_id: data.node_id, candidate_id: rpc.candidate_id, term: rpc.term})

      reply = %RequestVoteReply{
        term: data.current_term,
        vote_granted: true,
        from: data.node_id
      }
      RPC.send_reply(data.node_id, rpc.candidate_id, reply)

      # §5.2: reset election timeout when granting vote
      {:next_state, :follower, data,
       [{:state_timeout, election_timeout(), :election_timeout}]}
    else
      reason = vote_deny_reason(rpc, data)

      :telemetry.execute([:raft_ex, :vote, :denied], %{count: 1},
        %{node_id: data.node_id, candidate_id: rpc.candidate_id, reason: reason})

      reply = %RequestVoteReply{
        term: data.current_term,
        vote_granted: false,
        from: data.node_id
      }
      RPC.send_reply(data.node_id, rpc.candidate_id, reply)

      next_state = if rpc.term > data.current_term, do: :follower, else: current_role
      actions = if next_state == :follower,
        do: [{:state_timeout, election_timeout(), :election_timeout}],
        else: []
      {:next_state, next_state, data, actions}
    end
  end

  # §5.2: grant vote if:
  # 1. term >= currentTerm
  # 2. votedFor is null or candidateId
  # 3. candidate's log is at least as up-to-date as ours (§5.4.1)
  defp can_grant_vote?(rpc, data) do
    term_ok = rpc.term >= data.current_term
    vote_ok = data.voted_for == nil or data.voted_for == rpc.candidate_id
    log_ok  = log_up_to_date?(rpc.last_log_term, rpc.last_log_index, data.node_id)
    term_ok and vote_ok and log_ok
  end

  # §5.4.1: candidate's log is up-to-date if:
  # - its last term is higher, OR
  # - same last term and its log is at least as long
  defp log_up_to_date?(cand_last_term, cand_last_index, node_id) do
    my_last_term  = Log.last_term(node_id)
    my_last_index = Log.last_index(node_id)

    cond do
      cand_last_term > my_last_term  -> true
      cand_last_term < my_last_term  -> false
      true -> cand_last_index >= my_last_index
    end
  end

  defp vote_deny_reason(rpc, data) do
    cond do
      rpc.term < data.current_term -> :stale_term
      data.voted_for != nil and data.voted_for != rpc.candidate_id -> :already_voted
      not log_up_to_date?(rpc.last_log_term, rpc.last_log_index, data.node_id) -> :log_not_up_to_date
      true -> :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # AppendEntries handler — used by follower/candidate (§5.3)
  # ---------------------------------------------------------------------------

  defp handle_append_entries(%AppendEntries{} = rpc, data, current_role) do
    # §5.1: if RPC term > currentTerm, update term
    data = if rpc.term > data.current_term, do: step_down(data, rpc.term), else: data

    cond do
      # §5.3 Rule 1: reply false if term < currentTerm
      rpc.term < data.current_term ->
        reply = %AppendEntriesReply{term: data.current_term, success: false, from: data.node_id}
        RPC.send_reply(data.node_id, rpc.leader_id, reply)
        next_state = if current_role == :leader, do: :follower, else: current_role
        actions = [{:state_timeout, election_timeout(), :election_timeout}]
        {:next_state, next_state, data, actions}

      # §5.3 Rule 2: reply false if log doesn't contain prevLogIndex/prevLogTerm
      not Log.has_entry?(data.node_id, rpc.prev_log_index, rpc.prev_log_term) ->
        # Fast backtracking: send conflict info (§5.3 optimization)
        {conflict_index, conflict_term} = find_conflict(data.node_id, rpc.prev_log_index)
        reply = %AppendEntriesReply{
          term: data.current_term,
          success: false,
          from: data.node_id,
          conflict_index: conflict_index,
          conflict_term: conflict_term
        }
        RPC.send_reply(data.node_id, rpc.leader_id, reply)
        data = %{data | leader_id: rpc.leader_id}
        {:next_state, :follower, data,
         [{:state_timeout, election_timeout(), :election_timeout}]}

      true ->
        # §5.3 Rules 3+4: append entries (conflict-aware, idempotent)
        :ok = Log.append_entries(data.node_id, rpc.prev_log_index, rpc.entries)

        # §5.3 Rule 5: update commitIndex
        new_commit = if rpc.leader_commit > data.commit_index do
          last_new = if rpc.entries == [], do: rpc.prev_log_index,
                       else: elem(List.last(rpc.entries), 0)
          min(rpc.leader_commit, last_new)
        else
          data.commit_index
        end

        data = %{data | leader_id: rpc.leader_id, commit_index: new_commit}
        data = apply_committed_entries(data)

        match_index = if rpc.entries == [], do: rpc.prev_log_index,
                        else: elem(List.last(rpc.entries), 0)

        reply = %AppendEntriesReply{
          term: data.current_term,
          success: true,
          from: data.node_id,
          match_index: match_index
        }
        RPC.send_reply(data.node_id, rpc.leader_id, reply)

        {:next_state, :follower, data,
         [{:state_timeout, election_timeout(), :election_timeout}]}
    end
  end

  defp find_conflict(node_id, prev_log_index) do
    case Log.get(node_id, prev_log_index) do
      nil ->
        # Index doesn't exist — tell leader to back up to our last index
        last = Log.last_index(node_id)
        {max(1, last), nil}
      {_, term, _} ->
        # Index exists but wrong term — find first index of that term
        first = Log.first_index_for_term(node_id, term) || prev_log_index
        {first, term}
    end
  end

  # ---------------------------------------------------------------------------
  # Leader: client command handling (§5.3, §8)
  # ---------------------------------------------------------------------------

  defp handle_client_command(from, cmd, data) do
    # §5.3: leader appends entry to its log
    {:ok, index} = Log.append(data.node_id, data.current_term, cmd)

    :telemetry.execute([:raft_ex, :log, :appended], %{count: 1},
      %{node_id: data.node_id, index: index, term: data.current_term, command: cmd})

    # Track pending client call — reply when committed
    pending = Map.put(data.pending, index, {from, cmd})
    data = %{data | pending: pending}

    # Immediately replicate to all peers
    data = replicate_to_peers(data)

    # Check if single-node cluster (can commit immediately)
    data = maybe_advance_commit(data)

    {:keep_state, data, [{:timeout, @heartbeat_interval, :heartbeat}]}
  end

  # ---------------------------------------------------------------------------
  # Leader: heartbeat (§5.2)
  # ---------------------------------------------------------------------------

  defp send_heartbeats(data) do
    data = do_send_heartbeats(data)
    {:keep_state, data, [{:timeout, @heartbeat_interval, :heartbeat}]}
  end

  defp do_send_heartbeats(data) do
    for peer <- Cluster.peers(data.cluster, data.node_id) do
      send_append_entries_to(data, peer)
      :telemetry.execute([:raft_ex, :heartbeat, :sent], %{count: 1},
        %{node_id: data.node_id, to: peer})
    end
    data
  end

  defp replicate_to_peers(data) do
    for peer <- Cluster.peers(data.cluster, data.node_id) do
      send_append_entries_to(data, peer)
    end
    data
  end

  defp send_append_entries_to(data, peer) do
    next_idx = Map.get(data.next_index, peer, 1)
    prev_log_index = next_idx - 1
    prev_log_term  = Log.term_at(data.node_id, prev_log_index) || 0

    # §7: if nextIndex <= snapshot's last_included_index, send InstallSnapshot
    snap = Snapshot.load(data.node_id)
    if snap != nil and next_idx <= snap.last_included_index do
      rpc = %InstallSnapshot{
        term: data.current_term,
        leader_id: data.node_id,
        last_included_index: snap.last_included_index,
        last_included_term: snap.last_included_term,
        offset: 0,
        data: snap.data,
        done: true
      }
      RPC.send_rpc(data.node_id, peer, rpc)
    else
      entries = Log.get_from(data.node_id, next_idx)
      rpc = %AppendEntries{
        term: data.current_term,
        leader_id: data.node_id,
        prev_log_index: prev_log_index,
        prev_log_term: prev_log_term,
        entries: entries,
        leader_commit: data.commit_index
      }
      RPC.send_rpc(data.node_id, peer, rpc)
    end
  end

  # ---------------------------------------------------------------------------
  # Leader: handle AppendEntriesReply (§5.3)
  # ---------------------------------------------------------------------------

  defp handle_append_entries_reply(%AppendEntriesReply{} = reply, data) do
    # §5.1: if reply has higher term, step down
    if reply.term > data.current_term do
      data = step_down(data, reply.term)
      {:next_state, :follower, data,
       [{:state_timeout, election_timeout(), :election_timeout}]}
    else
      if reply.success do
        # §5.3: update nextIndex and matchIndex for this follower
        peer = reply.from
        new_match = max(Map.get(data.match_index, peer, 0), reply.match_index)
        new_next  = new_match + 1

        data = %{data |
          match_index: Map.put(data.match_index, peer, new_match),
          next_index:  Map.put(data.next_index, peer, new_next)
        }

        # §5.3, §5.4.2: try to advance commitIndex
        data = maybe_advance_commit(data)
        {:keep_state, data}
      else
        # §5.3: decrement nextIndex and retry (with fast backtracking)
        peer = reply.from
        current_next = Map.get(data.next_index, peer, 1)

        new_next =
          if reply.conflict_index != nil do
            # Fast backtracking: skip to first index of conflicting term
            case Log.first_index_for_term(data.node_id, reply.conflict_term) do
              nil -> reply.conflict_index
              idx -> idx
            end
          else
            max(1, current_next - 1)
          end

        data = %{data | next_index: Map.put(data.next_index, peer, new_next)}
        # Retry immediately
        send_append_entries_to(data, peer)
        {:keep_state, data}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Leader: handle InstallSnapshotReply (§7)
  # ---------------------------------------------------------------------------

  defp handle_install_snapshot_reply(%InstallSnapshotReply{} = reply, data) do
    if reply.term > data.current_term do
      data = step_down(data, reply.term)
      {:next_state, :follower, data,
       [{:state_timeout, election_timeout(), :election_timeout}]}
    else
      # §7: after snapshot installed, update nextIndex to last_included_index + 1
      snap = Snapshot.load(data.node_id)
      if snap != nil do
        peer = reply.from
        new_next  = snap.last_included_index + 1
        new_match = snap.last_included_index
        data = %{data |
          next_index:  Map.put(data.next_index, peer, new_next),
          match_index: Map.put(data.match_index, peer, new_match)
        }
        {:keep_state, data}
      else
        {:keep_state, data}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Leader: advance commitIndex (§5.3, §5.4.2)
  # ---------------------------------------------------------------------------

  defp maybe_advance_commit(data) do
    # §5.3: find highest N such that majority have matchIndex >= N
    # and log[N].term == currentTerm (§5.4.2)
    leader_match = Log.last_index(data.node_id)
    all_match = [leader_match | Map.values(data.match_index)]
    quorum_n = Cluster.quorum_match_index(all_match)

    # §5.4.2: only commit entries from current term
    entry_term = Log.term_at(data.node_id, quorum_n)

    if quorum_n > data.commit_index and entry_term == data.current_term do
      :telemetry.execute([:raft_ex, :log, :committed], %{count: 1},
        %{node_id: data.node_id, commit_index: quorum_n})

      data = %{data | commit_index: quorum_n}
      apply_committed_entries(data)
    else
      data
    end
  end

  # ---------------------------------------------------------------------------
  # Apply committed entries to state machine (§5.3)
  # ---------------------------------------------------------------------------

  defp apply_committed_entries(data) do
    if data.commit_index > data.last_applied do
      entries = Log.get_range(data.node_id, data.last_applied + 1, data.commit_index)
      {new_sm, results} = StateMachine.apply_entries(data.sm_state, entries)

      # Emit telemetry and reply to pending clients
      data = Enum.reduce(results, data, fn {index, result}, acc ->
        :telemetry.execute([:raft_ex, :log, :applied], %{count: 1},
          %{node_id: acc.node_id, index: index, result: result})

        # Reply to pending client call if any
        case Map.pop(acc.pending, index) do
          {{from, _cmd}, new_pending} ->
            :gen_statem.reply(from, {:ok, result})
            %{acc | pending: new_pending}
          {nil, _} ->
            acc
        end
      end)

      last_applied = data.commit_index
      %{data | sm_state: new_sm, last_applied: last_applied}
    else
      data
    end
  end

  # ---------------------------------------------------------------------------
  # InstallSnapshot handler — follower receives snapshot from leader (§7)
  # ---------------------------------------------------------------------------

  defp handle_install_snapshot(%InstallSnapshot{} = rpc, data) do
    data = if rpc.term > data.current_term, do: step_down(data, rpc.term), else: data

    if rpc.term < data.current_term do
      reply = %InstallSnapshotReply{term: data.current_term, from: data.node_id}
      RPC.send_reply(data.node_id, rpc.leader_id, reply)
      {:keep_state, data}
    else
      snap = %{
        last_included_index: rpc.last_included_index,
        last_included_term:  rpc.last_included_term,
        cluster: data.cluster,
        data: rpc.data
      }

      {:ok, new_sm} = Snapshot.install(data.node_id, snap)

      new_commit = max(data.commit_index, rpc.last_included_index)
      new_applied = max(data.last_applied, rpc.last_included_index)

      data = %{data |
        sm_state: new_sm,
        commit_index: new_commit,
        last_applied: new_applied,
        leader_id: rpc.leader_id
      }

      reply = %InstallSnapshotReply{term: data.current_term, from: data.node_id}
      RPC.send_reply(data.node_id, rpc.leader_id, reply)

      {:next_state, :follower, data,
       [{:state_timeout, election_timeout(), :election_timeout}]}
    end
  end

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  # §5.1: if we see a higher term, update currentTerm, clear vote, revert to follower
  defp step_down(data, new_term) do
    :ok = Persistence.save_term(data.node_id, new_term)
    :ok = Persistence.clear_vote(data.node_id)

    :telemetry.execute([:raft_ex, :election, :lost], %{count: 1},
      %{node_id: data.node_id, term: new_term})

    %{data | current_term: new_term, voted_for: nil, leader_id: nil}
  end

  defp maybe_update_term(data, term) do
    if term > data.current_term, do: step_down(data, term), else: data
  end

  defp election_timeout() do
    # §5.2: randomized between 150ms and 300ms
    @election_timeout_min + :rand.uniform(@election_timeout_max - @election_timeout_min)
  end

  defp server_name(node_id), do: :"raft_server_#{node_id}"

  defp build_status(data, role) do
    %{
      node_id: data.node_id,
      role: role,
      current_term: data.current_term,
      voted_for: data.voted_for,
      commit_index: data.commit_index,
      last_applied: data.last_applied,
      leader_id: data.leader_id,
      log_last_index: Log.last_index(data.node_id),
      log_last_term: Log.last_term(data.node_id),
      sm_state: data.sm_state
    }
  end
end
