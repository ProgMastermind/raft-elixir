defmodule RaftEx.Log do
  @moduledoc """
  Raft log storage — DETS-backed, persistent, conflict-aware. (§5.3)

  The log is the central data structure in Raft. Each entry contains:
  - `index`   — 1-based position in the log (first index is 1)
  - `term`    — the term when the entry was received by the leader
  - `command` — the command to apply to the state machine

  ## Key invariants (§5.3)

  1. If two entries in different logs have the same index and term, they store
     the same command. (Log Matching Property)
  2. If two entries in different logs have the same index and term, all
     preceding entries are identical. (Log Matching Property)
  3. Indices are always sequential and monotonically increasing (1, 2, 3, ...).

  ## Conflict resolution (§5.3)

  When a follower receives AppendEntries with entries that conflict with its
  own log (same index, different term), it MUST delete the conflicting entry
  and all that follow it, then append the leader's entries. This is handled
  by `append_entries/3`.

  ## DETS table layout

  One DETS file per node: `raft_ex_{node_id}_log.dets` in the system tmp dir.
  Entries stored as: `{index :: pos_integer(), term :: non_neg_integer(), command :: term()}`

  ## Usage

      {:ok, _} = RaftEx.Log.open(:n1)
      {:ok, 1} = RaftEx.Log.append(:n1, 1, {:set, "x", 42})
      {1, 1, {:set, "x", 42}} = RaftEx.Log.get(:n1, 1)
      1 = RaftEx.Log.last_index(:n1)
      RaftEx.Log.close(:n1)
  """

  # ---------------------------------------------------------------------------
  # Public API — lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Open (or create) the DETS log table for `node_id`.
  Must be called before any other function.
  """
  @spec open(atom()) :: {:ok, :dets.tab_name()} | {:error, term()}
  def open(node_id) do
    path = table_path(node_id)
    :dets.open_file(table_name(node_id), file: path, type: :set)
  end

  @doc """
  Close the DETS log table for `node_id`.
  """
  @spec close(atom()) :: :ok
  def close(node_id) do
    :dets.close(table_name(node_id))
  end

  # ---------------------------------------------------------------------------
  # Public API — reads
  # ---------------------------------------------------------------------------

  @doc """
  Get the log entry at `index`. Returns `{index, term, command}` or `nil`.
  """
  @spec get(atom(), pos_integer()) :: {pos_integer(), non_neg_integer(), term()} | nil
  def get(node_id, index) do
    case :dets.lookup(table_name(node_id), index) do
      [{^index, term, command}] -> {index, term, command}
      [] -> nil
    end
  end

  @doc """
  Get the term of the entry at `index`.

  Returns 0 for index 0 (the base case — before the log starts). (§5.3)
  Returns nil if the index is beyond the log.
  """
  @spec term_at(atom(), non_neg_integer()) :: non_neg_integer() | nil
  def term_at(_node_id, 0), do: 0

  def term_at(node_id, index) do
    case get(node_id, index) do
      {_, term, _} -> term
      nil -> nil
    end
  end

  @doc """
  Get the index of the last log entry. Returns 0 if the log is empty. (§5.3)
  """
  @spec last_index(atom()) :: non_neg_integer()
  def last_index(node_id) do
    # §5.3: first index is 1; 0 means empty log
    case :dets.info(table_name(node_id), :size) do
      0 -> 0
      _ -> find_last_index(node_id)
    end
  end

  @doc """
  Get the term of the last log entry. Returns 0 if the log is empty. (§5.3)
  """
  @spec last_term(atom()) :: non_neg_integer()
  def last_term(node_id) do
    idx = last_index(node_id)
    if idx == 0, do: 0, else: term_at(node_id, idx)
  end

  @doc """
  Get the number of entries in the log.
  """
  @spec length(atom()) :: non_neg_integer()
  def length(node_id) do
    :dets.info(table_name(node_id), :size) || 0
  end

  @doc """
  Get all entries in the range `[from_index, to_index]` (inclusive), sorted by index.
  """
  @spec get_range(atom(), pos_integer(), pos_integer()) ::
          [{pos_integer(), non_neg_integer(), term()}]
  def get_range(node_id, from_index, to_index) do
    tab = table_name(node_id)

    :dets.select(tab, [
      {{:"$1", :"$2", :"$3"},
       [{:andalso, {:>=, :"$1", from_index}, {:"=<", :"$1", to_index}}],
       [{{:"$1", :"$2", :"$3"}}]}
    ])
    |> Enum.sort_by(fn {idx, _, _} -> idx end)
  end

  @doc """
  Get all entries from `from_index` to the end of the log, sorted by index.
  """
  @spec get_from(atom(), pos_integer()) :: [{pos_integer(), non_neg_integer(), term()}]
  def get_from(node_id, from_index) do
    get_range(node_id, from_index, last_index(node_id))
  end

  @doc """
  Check if the log contains an entry at `index` with the given `term`.

  Returns true for index=0, term=0 (the empty log base case). (§5.3)
  This is used by followers to verify prevLogIndex/prevLogTerm in AppendEntries.
  """
  @spec has_entry?(atom(), non_neg_integer(), non_neg_integer()) :: boolean()
  def has_entry?(_node_id, 0, 0), do: true

  def has_entry?(node_id, index, term) do
    case get(node_id, index) do
      {^index, ^term, _} -> true
      _ -> false
    end
  end

  @doc """
  Get the first log index that has the given `term`.
  Used for fast log backtracking (§5.3 optimization).
  Returns nil if no entry with that term exists.
  """
  @spec first_index_for_term(atom(), non_neg_integer()) :: pos_integer() | nil
  def first_index_for_term(node_id, term) do
    tab = table_name(node_id)

    results =
      :dets.select(tab, [
        {{:"$1", :"$2", :_}, [{:==, :"$2", term}], [:"$1"]}
      ])

    case Enum.sort(results) do
      [] -> nil
      [first | _] -> first
    end
  end

  # ---------------------------------------------------------------------------
  # Public API — writes
  # ---------------------------------------------------------------------------

  @doc """
  Append a single new entry to the log. Returns `{:ok, new_index}`.

  The index is automatically assigned as `last_index + 1`. (§5.3)
  Leaders use this to append client commands before replicating.
  """
  @spec append(atom(), non_neg_integer(), term()) :: {:ok, pos_integer()}
  def append(node_id, term, command) do
    # §5.3: log entries are 1-based; new index = last + 1
    new_index = last_index(node_id) + 1
    tab = table_name(node_id)
    :ok = :dets.insert(tab, {new_index, term, command})
    :ok = :dets.sync(tab)
    {:ok, new_index}
  end

  @doc """
  Apply a list of entries from a leader's AppendEntries RPC. (§5.3)

  This implements the full conflict-resolution logic from Figure 2:
  1. Skip entries that already exist with the same index AND term (idempotent).
  2. If an existing entry conflicts (same index, different term), truncate
     from that index onward, then append all remaining new entries.
  3. Append any new entries not already in the log.

  `prev_log_index` is the index before the first entry in `entries`.
  """
  @spec append_entries(atom(), non_neg_integer(), [{pos_integer(), non_neg_integer(), term()}]) ::
          :ok
  def append_entries(_node_id, _prev_log_index, []), do: :ok

  def append_entries(node_id, _prev_log_index, entries) do
    Enum.reduce_while(entries, :ok, fn {index, term, command}, _acc ->
      case get(node_id, index) do
        {^index, ^term, _} ->
          # §5.3: same index + same term → already have this entry, skip (idempotent)
          {:cont, :ok}

        {^index, _different_term, _} ->
          # §5.3: conflict — delete this entry and all that follow, then append rest
          truncate_from(node_id, index)
          append_remaining(node_id, [{index, term, command} | entries_from(entries, index + 1)])
          {:halt, :ok}

        nil ->
          # New entry — append it and all remaining
          append_remaining(node_id, [{index, term, command} | entries_from(entries, index + 1)])
          {:halt, :ok}
      end
    end)

    :dets.sync(table_name(node_id))
    :ok
  end

  @doc """
  Delete all log entries from `from_index` onward (inclusive). (§5.3)

  Used when a follower detects a conflict with the leader's log.
  Leaders NEVER call this — they only append. (§5.4)
  """
  @spec truncate_from(atom(), pos_integer()) :: :ok
  def truncate_from(node_id, from_index) do
    tab = table_name(node_id)
    last = last_index(node_id)

    # §5.3: delete from_index..last_index
    for idx <- from_index..last do
      :dets.delete(tab, idx)
    end

    :dets.sync(tab)
    :ok
  end

  @doc """
  Delete all log entries up to and including `up_to_index`. (§7)

  Used after a snapshot is taken to compact the log. Entries covered
  by the snapshot are no longer needed.
  """
  @spec truncate_up_to(atom(), non_neg_integer()) :: :ok
  def truncate_up_to(_node_id, 0), do: :ok

  def truncate_up_to(node_id, up_to_index) do
    tab = table_name(node_id)

    # §7: discard entries covered by the snapshot
    for idx <- 1..up_to_index do
      :dets.delete(tab, idx)
    end

    :dets.sync(tab)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_last_index(node_id) do
    tab = table_name(node_id)
    indices = :dets.select(tab, [{{:"$1", :_, :_}, [], [:"$1"]}])

    case indices do
      [] -> 0
      _ -> Enum.max(indices)
    end
  end

  defp append_remaining(_node_id, []), do: :ok

  defp append_remaining(node_id, entries) do
    tab = table_name(node_id)

    for {index, term, command} <- entries do
      :dets.insert(tab, {index, term, command})
    end

    :ok
  end

  defp entries_from(entries, from_index) do
    Enum.filter(entries, fn {idx, _, _} -> idx >= from_index end)
  end

  @doc false
  def table_name(node_id) do
    :"raft_ex_#{node_id}_log"
  end

  @doc false
  def table_path(node_id) do
    tmp = System.tmp_dir!()
    Path.join(tmp, "raft_ex_#{node_id}_log.dets") |> String.to_charlist()
  end
end
