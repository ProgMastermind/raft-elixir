defmodule RaftEx.RPC do
  alias RaftEx.TcpTransport
  @moduledoc """
  Raft RPC message structs and dispatch layer. (§5.2, §5.3, §7)

  Defines all 6 message types from the Raft paper Figure 2 plus the
  InstallSnapshot RPC from §7. All inter-node communication goes through
  `send_rpc/3` and `send_reply/3` — no bare `send/2` calls anywhere.

  ## Message types

  ### RequestVote (§5.2, §5.4)
  Sent by candidates to gather votes during an election.

  ### RequestVoteReply (§5.2)
  Sent by servers in response to RequestVote.

  ### AppendEntries (§5.3)
  Sent by the leader to replicate log entries and as heartbeats.
  Empty `entries` = heartbeat.

  ### AppendEntriesReply (§5.3)
  Sent by followers in response to AppendEntries.

  ### InstallSnapshot (§7)
  Sent by the leader to followers that are too far behind to catch up
  via normal AppendEntries (their nextIndex is before the snapshot).

  ### InstallSnapshotReply (§7)
  Sent by followers in response to InstallSnapshot.

  ## Dispatch

  All RPCs are sent via `:gen_statem.cast/2` (fire-and-forget) using the
  registered process name `raft_server_{node_id}`. This avoids distributed
  Erlang and works for single-BEAM multi-node demos.
  """

  # ---------------------------------------------------------------------------
  # PreVote (optimization before §5.2 election)
  # ---------------------------------------------------------------------------

  defmodule PreVote do
    @moduledoc """
    PreVote RPC — probe for election viability before incrementing term.
    """
    @enforce_keys [:term, :candidate_id, :last_log_index, :last_log_term]
    defstruct [:term, :candidate_id, :last_log_index, :last_log_term]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            candidate_id: atom(),
            last_log_index: non_neg_integer(),
            last_log_term: non_neg_integer()
          }
  end

  defmodule PreVoteReply do
    @moduledoc """
    PreVoteReply — response to PreVote viability probe.
    """
    @enforce_keys [:term, :vote_granted, :from]
    defstruct [:term, :vote_granted, :from]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            vote_granted: boolean(),
            from: atom()
          }
  end

  # ---------------------------------------------------------------------------
  # RequestVote (§5.2, §5.4)
  # ---------------------------------------------------------------------------

  defmodule RequestVote do
    @moduledoc """
    RequestVote RPC — sent by candidates to gather votes. (§5.2, §5.4)

    Fields (Figure 2):
    - `term`          — candidate's current term
    - `candidate_id`  — candidate requesting the vote
    - `last_log_index`— index of candidate's last log entry (§5.4)
    - `last_log_term` — term of candidate's last log entry (§5.4)
    """
    @enforce_keys [:term, :candidate_id, :last_log_index, :last_log_term]
    defstruct [:term, :candidate_id, :last_log_index, :last_log_term]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            candidate_id: atom(),
            last_log_index: non_neg_integer(),
            last_log_term: non_neg_integer()
          }
  end

  # ---------------------------------------------------------------------------
  # RequestVoteReply (§5.2)
  # ---------------------------------------------------------------------------

  defmodule RequestVoteReply do
    @moduledoc """
    RequestVoteReply — response to RequestVote. (§5.2)

    Fields (Figure 2):
    - `term`         — currentTerm, for candidate to update itself
    - `vote_granted` — true means candidate received the vote
    - `from`         — node_id of the voter (not in paper, needed for routing)
    """
    @enforce_keys [:term, :vote_granted, :from]
    defstruct [:term, :vote_granted, :from]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            vote_granted: boolean(),
            from: atom()
          }
  end

  # ---------------------------------------------------------------------------
  # AppendEntries (§5.3)
  # ---------------------------------------------------------------------------

  defmodule AppendEntries do
    @moduledoc """
    AppendEntries RPC — sent by leader to replicate entries and as heartbeat. (§5.3)

    Fields (Figure 2):
    - `term`          — leader's current term
    - `leader_id`     — so followers can redirect clients (§8)
    - `prev_log_index`— index of log entry immediately preceding new ones
    - `prev_log_term` — term of prevLogIndex entry
    - `entries`       — log entries to store (empty list = heartbeat)
    - `leader_commit` — leader's commitIndex
    """
    @enforce_keys [:term, :leader_id, :prev_log_index, :prev_log_term, :entries, :leader_commit]
    defstruct [:term, :leader_id, :prev_log_index, :prev_log_term, :entries, :leader_commit]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            leader_id: atom(),
            prev_log_index: non_neg_integer(),
            prev_log_term: non_neg_integer(),
            entries: [{pos_integer(), non_neg_integer(), term()}],
            leader_commit: non_neg_integer()
          }
  end

  # ---------------------------------------------------------------------------
  # AppendEntriesReply (§5.3)
  # ---------------------------------------------------------------------------

  defmodule AppendEntriesReply do
    @moduledoc """
    AppendEntriesReply — response to AppendEntries. (§5.3)

    Fields (Figure 2 + optimizations):
    - `term`           — currentTerm, for leader to update itself
    - `success`        — true if follower matched prevLogIndex/prevLogTerm
    - `from`           — node_id of the follower (needed for routing)
    - `match_index`    — highest index known to be replicated on this follower
    - `conflict_index` — first index of the conflicting term (fast backtracking)
    - `conflict_term`  — term of the conflicting entry (fast backtracking)
    """
    @enforce_keys [:term, :success, :from]
    defstruct [:term, :success, :from, match_index: 0, conflict_index: nil, conflict_term: nil]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            success: boolean(),
            from: atom(),
            match_index: non_neg_integer(),
            conflict_index: pos_integer() | nil,
            conflict_term: non_neg_integer() | nil
          }
  end

  # ---------------------------------------------------------------------------
  # InstallSnapshot (§7)
  # ---------------------------------------------------------------------------

  defmodule InstallSnapshot do
    @moduledoc """
    InstallSnapshot RPC — sent by leader to bring lagging followers up to date. (§7)

    Fields (§7):
    - `term`                — leader's current term
    - `leader_id`           — so followers can redirect clients
    - `last_included_index` — index of last entry covered by the snapshot
    - `last_included_term`  — term of last entry covered by the snapshot
    - `offset`              — byte offset in snapshot file (0 for single-chunk)
    - `data`                — raw snapshot data (serialized state machine)
    - `done`                — true if this is the last chunk
    """
    @enforce_keys [
      :term,
      :leader_id,
      :last_included_index,
      :last_included_term,
      :offset,
      :data,
      :done
    ]
    defstruct [
      :term,
      :leader_id,
      :last_included_index,
      :last_included_term,
      :offset,
      :data,
      :done
    ]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            leader_id: atom(),
            last_included_index: pos_integer(),
            last_included_term: non_neg_integer(),
            offset: non_neg_integer(),
            data: binary(),
            done: boolean()
          }
  end

  # ---------------------------------------------------------------------------
  # InstallSnapshotReply (§7)
  # ---------------------------------------------------------------------------

  defmodule InstallSnapshotReply do
    @moduledoc """
    InstallSnapshotReply — response to InstallSnapshot. (§7)

    Fields (§7):
    - `term`  — currentTerm, for leader to update itself
    - `from`  — node_id of the follower
    """
    @enforce_keys [:term, :from]
    defstruct [:term, :from]

    @type t :: %__MODULE__{
            term: non_neg_integer(),
            from: atom()
          }
  end

  # ---------------------------------------------------------------------------
  # Dispatch — no bare send/2 for Raft RPCs
  # ---------------------------------------------------------------------------

  @doc """
  Send a Raft RPC to `peer_id` via `:gen_statem.cast/2`.

  Uses the registered process name `raft_server_{peer_id}` to locate the
  peer process. Fire-and-forget — no response expected on this call.
  """
  @spec send_rpc(atom(), atom(), term()) :: :ok
  def send_rpc(from_id, peer_id, rpc) do
    :telemetry.execute(
      [:raft_ex, :rpc, :sent],
      %{count: 1},
      %{node_id: from_id, to: peer_id, rpc: rpc.__struct__ |> Module.split() |> List.last()}
    )

    case TcpTransport.send(peer_id, rpc) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:raft_ex, :transport, :send_error],
          %{count: 1},
          %{node_id: from_id, to: peer_id, reason: reason}
        )

        :ok
    end
  end

  @doc """
  Send a Raft RPC reply back to `peer_id` via `:gen_statem.cast/2`.

  Used by followers to send RequestVoteReply and AppendEntriesReply back
  to the candidate/leader.
  """
  @spec send_reply(atom(), atom(), term()) :: :ok
  def send_reply(from_id, peer_id, reply) do
    :telemetry.execute(
      [:raft_ex, :rpc, :reply_sent],
      %{count: 1},
      %{node_id: from_id, to: peer_id, rpc: reply.__struct__ |> Module.split() |> List.last()}
    )

    case TcpTransport.send(peer_id, reply) do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:raft_ex, :transport, :send_error],
          %{count: 1},
          %{node_id: from_id, to: peer_id, reason: reason}
        )

        :ok
    end
  end
end
