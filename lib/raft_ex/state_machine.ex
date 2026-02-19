defmodule RaftEx.StateMachine do
  @moduledoc """
  Application state machine — a replicated key-value store. (§5.3)

  The state machine is what Raft is protecting. Once a log entry is
  committed (replicated to a majority), it is applied to the state machine
  in log order. The state machine is deterministic: given the same sequence
  of commands, every server produces the same state.

  ## Commands

  - `{:set, key, value}` — store a value
  - `{:get, key}`        — read a value (returns nil if missing)
  - `{:delete, key}`     — remove a key
  - `{:noop}`            — no-op (used by leader on election, §8)

  ## Serialization

  The state machine state is a plain Elixir map. It is serialized to binary
  using `:erlang.term_to_binary/1` for snapshot storage (§7).

  ## Usage

      state = RaftEx.StateMachine.new()
      {state, {:ok, 42}} = RaftEx.StateMachine.apply_command(state, {:set, "x", 42})
      {state, {:ok, 42}} = RaftEx.StateMachine.apply_command(state, {:get, "x"})
      {state, :ok}       = RaftEx.StateMachine.apply_command(state, {:delete, "x"})
  """

  @type state :: %{optional(term()) => term()}
  @type command ::
          {:set, term(), term()}
          | {:get, term()}
          | {:delete, term()}
          | {:noop}
          | {:config_change, [atom()]}
          | {:config_change_joint, [atom()], [atom()]}
          | {:config_change_finalize, [atom()]}
  @type result :: {:ok, term()} | :ok

  @doc """
  Create a new, empty state machine.
  """
  @spec new() :: state()
  def new(), do: %{}

  @doc """
  Apply a single command to the state machine. (§5.3)

  Returns `{new_state, result}`. The result is returned to the client
  after the entry is committed and applied.
  """
  @spec apply_command(state(), command()) :: {state(), result()}
  def apply_command(state, {:set, key, value}) do
    # §5.3: deterministic — same command always produces same result
    {Map.put(state, key, value), {:ok, value}}
  end

  def apply_command(state, {:get, key}) do
    {state, {:ok, Map.get(state, key)}}
  end

  def apply_command(state, {:delete, key}) do
    {Map.delete(state, key), :ok}
  end

  def apply_command(state, {:noop}) do
    # §8: no-op appended by leader on election — does not change state
    {state, :ok}
  end

  def apply_command(state, {:config_change, _new_cluster}) do
    # §6: cluster membership change — handled at server level, not KV level
    {state, :ok}
  end

  def apply_command(state, {:config_change_joint, _old_cluster, _new_cluster}) do
    {state, :ok}
  end

  def apply_command(state, {:config_change_finalize, _new_cluster}) do
    {state, :ok}
  end

  @doc """
  Apply a list of log entries to the state machine in order. (§5.3)

  Each entry is `{index, term, command}`. Returns `{final_state, results}`
  where `results` is a list of `{index, result}` pairs.

  `lastApplied` only moves forward — entries are applied in index order.
  """
  @spec apply_entries(state(), [{pos_integer(), non_neg_integer(), command()}]) ::
          {state(), [{pos_integer(), result()}]}
  def apply_entries(state, entries) do
    Enum.reduce(entries, {state, []}, fn {index, _term, command}, {acc_state, acc_results} ->
      {new_state, result} = apply_command(acc_state, command)
      {new_state, acc_results ++ [{index, result}]}
    end)
  end

  @doc """
  Serialize the state machine state to binary for snapshot storage. (§7)
  """
  @spec serialize(state()) :: binary()
  def serialize(state) do
    :erlang.term_to_binary(state)
  end

  @doc """
  Deserialize a binary snapshot back to state machine state. (§7)
  """
  @spec deserialize(binary()) :: state()
  def deserialize(binary) do
    :erlang.binary_to_term(binary)
  end
end
