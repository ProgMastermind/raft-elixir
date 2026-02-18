defmodule RaftEx.Persistence do
  @moduledoc """
  Persistent state storage for a Raft server node. (§5.1)

  Stores `currentTerm` and `votedFor` in a DETS table so they survive
  process crashes and node restarts. These two fields are the minimum
  persistent state required by the Raft paper to maintain safety.

  ## Why persistence matters (§5.1)

  The Raft paper requires that persistent state be written to stable storage
  **before** responding to any RPC. If a server crashes and restarts, it must
  be able to recover its term and vote to avoid:
  - Voting for two different candidates in the same term
  - Accepting a leader with a stale term

  ## DETS table layout

  One DETS file per node: `raft_ex_{node_id}_meta.dets` in the system tmp dir.

  Keys stored:
  - `{:current_term, non_neg_integer()}` — latest term seen
  - `{:voted_for, atom() | nil}` — candidateId voted for in current term

  ## Usage

      {:ok, _} = RaftEx.Persistence.open(:n1)
      RaftEx.Persistence.save_term(:n1, 3)
      RaftEx.Persistence.save_vote(:n1, :n2)
      3 = RaftEx.Persistence.load_term(:n1)
      :n2 = RaftEx.Persistence.load_vote(:n1)
      RaftEx.Persistence.close(:n1)
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Open (or create) the DETS persistence table for `node_id`.

  Must be called before any other function. Safe to call multiple times —
  DETS will reuse an already-open table.
  """
  @spec open(atom()) :: {:ok, :dets.tab_name()} | {:error, term()}
  def open(node_id) do
    path = table_path(node_id)
    :dets.open_file(table_name(node_id), file: path, type: :set)
  end

  @doc """
  Close the DETS table for `node_id`. Called on node shutdown.
  """
  @spec close(atom()) :: :ok
  def close(node_id) do
    :dets.close(table_name(node_id))
  end

  @doc """
  Persist `currentTerm` to stable storage. (§5.1)

  MUST be called before responding to any RPC that depends on the term.
  Uses `:dets.sync/1` to guarantee the write is flushed to disk.
  """
  @spec save_term(atom(), non_neg_integer()) :: :ok
  def save_term(node_id, term) do
    # §5.1: Write to stable storage BEFORE responding to RPCs
    tab = table_name(node_id)
    :ok = :dets.insert(tab, {:current_term, term})
    :ok = :dets.sync(tab)
  end

  @doc """
  Persist `votedFor` to stable storage. (§5.1)

  MUST be called before sending a RequestVoteReply granting the vote.
  Uses `:dets.sync/1` to guarantee the write is flushed to disk.
  """
  @spec save_vote(atom(), atom() | nil) :: :ok
  def save_vote(node_id, candidate_id) do
    # §5.1: Write to stable storage BEFORE responding to RPCs
    tab = table_name(node_id)
    :ok = :dets.insert(tab, {:voted_for, candidate_id})
    :ok = :dets.sync(tab)
  end

  @doc """
  Clear `votedFor` (set to nil). Called when term advances. (§5.1)

  When a server sees a higher term, it must reset its vote so it can
  vote again in the new term.
  """
  @spec clear_vote(atom()) :: :ok
  def clear_vote(node_id) do
    save_vote(node_id, nil)
  end

  @doc """
  Load `currentTerm` from stable storage.

  Returns 0 if not found (initial state on first boot). (§5.1)
  """
  @spec load_term(atom()) :: non_neg_integer()
  def load_term(node_id) do
    case :dets.lookup(table_name(node_id), :current_term) do
      [{:current_term, term}] -> term
      # §5.1: initialized to 0 on first boot
      [] -> 0
    end
  end

  @doc """
  Load `votedFor` from stable storage.

  Returns nil if not found (no vote cast yet in this term). (§5.1)
  """
  @spec load_vote(atom()) :: atom() | nil
  def load_vote(node_id) do
    case :dets.lookup(table_name(node_id), :voted_for) do
      [{:voted_for, candidate_id}] -> candidate_id
      # §5.1: null if none
      [] -> nil
    end
  end

  @doc """
  Load both `currentTerm` and `votedFor` in a single call.

  Returns `{term, voted_for}`. Used during server initialization.
  """
  @spec load_all(atom()) :: {non_neg_integer(), atom() | nil}
  def load_all(node_id) do
    {load_term(node_id), load_vote(node_id)}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @doc false
  def table_name(node_id) do
    :"raft_ex_#{node_id}_meta"
  end

  @doc false
  def table_path(node_id) do
    tmp = System.tmp_dir!()
    Path.join(tmp, "raft_ex_#{node_id}_meta.dets") |> String.to_charlist()
  end
end
