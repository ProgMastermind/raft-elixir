defmodule RaftEx.Snapshot do
  @moduledoc """
  Snapshot creation, storage, and installation for log compaction. (§7)

  Snapshots allow Raft to discard old log entries that have already been
  applied to the state machine, preventing unbounded log growth.

  ## When to snapshot (§7)

  The leader takes a snapshot when the log grows beyond a threshold
  (`threshold/0` entries). After creating a snapshot, log entries up to
  `last_included_index` are discarded.

  ## InstallSnapshot (§7)

  When a follower is so far behind that the leader has already discarded
  the log entries the follower needs, the leader sends an InstallSnapshot
  RPC instead of AppendEntries. The follower replaces its state machine
  state with the snapshot and discards its log.

  ## Snapshot file format

  Stored as a binary file: `raft_ex_{node_id}_snapshot.bin` in tmp dir.
  Contents: `:erlang.term_to_binary(snapshot_map)` where snapshot_map is:

      %{
        last_included_index: pos_integer(),
        last_included_term:  non_neg_integer(),
        cluster:             [atom()],
        data:                binary()   # serialized state machine
      }
  """

  alias RaftEx.Log

  # Number of log entries before triggering a snapshot (§7)
  @snapshot_threshold 100

  @doc """
  Return the snapshot threshold — number of log entries before snapshotting.
  """
  @spec threshold() :: pos_integer()
  def threshold(), do: @snapshot_threshold

  @doc """
  Return true if the log has grown large enough to warrant a snapshot. (§7)
  """
  @spec should_snapshot?(atom()) :: boolean()
  def should_snapshot?(node_id) do
    Log.length(node_id) >= @snapshot_threshold
  end

  @doc """
  Create a snapshot of the current state machine state and persist it. (§7)

  After saving the snapshot, discards log entries 1..last_included_index
  via `Log.truncate_up_to/2`.

  Returns `{:ok, snapshot}` where snapshot is the map written to disk.
  """
  @spec create(atom(), pos_integer(), non_neg_integer(), map(), [atom()]) ::
          {:ok, map()} | {:error, term()}
  def create(node_id, last_included_index, last_included_term, sm_state, cluster) do
    snapshot = %{
      last_included_index: last_included_index,
      last_included_term: last_included_term,
      cluster: cluster,
      # §7: snapshot contains serialized state machine state
      data: RaftEx.StateMachine.serialize(sm_state)
    }

    path = snapshot_path(node_id)

    case File.write(path, :erlang.term_to_binary(snapshot)) do
      :ok ->
        # §7: discard log entries covered by the snapshot
        :ok = Log.truncate_up_to(node_id, last_included_index)
        :ok = Log.set_snapshot_base(node_id, last_included_index, last_included_term)

        :telemetry.execute(
          [:raft_ex, :snapshot, :created],
          %{count: 1},
          %{
            node_id: node_id,
            last_included_index: last_included_index,
            last_included_term: last_included_term
          }
        )

        {:ok, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Load the most recent snapshot from disk. (§7)

  Returns the snapshot map or nil if no snapshot exists.
  """
  @spec load(atom()) :: map() | nil
  def load(node_id) do
    path = snapshot_path(node_id)

    case File.read(path) do
      {:ok, binary} ->
        :erlang.binary_to_term(binary)

      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Install a snapshot received via InstallSnapshot RPC. (§7)

  Replaces the node's log and state machine with the snapshot contents.
  Discards all log entries up to last_included_index.

  Returns `{:ok, sm_state}` where sm_state is the deserialized state machine.
  """
  @spec install(atom(), map()) :: {:ok, map()} | {:error, term()}
  def install(node_id, snapshot) do
    %{
      last_included_index: last_included_index,
      last_included_term: last_included_term,
      data: data
    } = snapshot

    path = snapshot_path(node_id)

    case File.write(path, :erlang.term_to_binary(snapshot)) do
      :ok ->
        # §7: discard all log entries — snapshot supersedes them
        :ok = Log.truncate_up_to(node_id, last_included_index)
        :ok = Log.set_snapshot_base(node_id, last_included_index, last_included_term)

        sm_state = RaftEx.StateMachine.deserialize(data)

        :telemetry.execute(
          [:raft_ex, :snapshot, :installed],
          %{count: 1},
          %{
            node_id: node_id,
            last_included_index: last_included_index,
            last_included_term: last_included_term
          }
        )

        {:ok, sm_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  def snapshot_path(node_id) do
    tmp = System.tmp_dir!()
    Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin")
  end
end
