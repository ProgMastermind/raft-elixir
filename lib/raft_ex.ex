defmodule RaftEx do
  @moduledoc """
  RaftEx — Public API for the Raft consensus cluster. (§8)

  Provides a simple interface to start nodes, submit commands, and
  query state. All commands are linearizable — they block until the
  entry is committed to a majority of nodes.

  ## Quick start

      # Start a 3-node cluster
      {:ok, _} = RaftEx.start_node(:n1, [:n1, :n2, :n3])
      {:ok, _} = RaftEx.start_node(:n2, [:n1, :n2, :n3])
      {:ok, _} = RaftEx.start_node(:n3, [:n1, :n2, :n3])

      # Wait for leader election (~300ms)
      Process.sleep(500)

      # Submit commands (auto-routed to leader)
      {:ok, 42} = RaftEx.set(:n1, "x", 42)
      {:ok, 42} = RaftEx.get(:n1, "x")
      :ok       = RaftEx.delete(:n1, "x")
  """

  alias RaftEx.{Server, Transport}

  @doc """
  Start a Raft node with the given `node_id` and `cluster` list.

  The cluster list must include `node_id` itself. All nodes in the
  cluster must be started with the same cluster list.

  Optional `opts`:
  - `:endpoints` => `%{node_id => {host, port}}` TCP endpoint map.
  """
  @spec start_node(atom(), [atom()], keyword()) :: {:ok, pid()} | {:error, term()}
  def start_node(node_id, cluster, opts \\ []) do
    endpoints = Keyword.get(opts, :endpoints, %{})
    _ = Transport.ensure_cluster_endpoints(cluster, endpoints)

    DynamicSupervisor.start_child(
      RaftEx.NodeSupervisor,
      {Server, {node_id, cluster}}
    )
  end

  @doc """
  Stop a Raft node.
  """
  @spec stop_node(atom()) :: :ok | {:error, term()}
  def stop_node(node_id) do
    name = :"raft_server_#{node_id}"
    case Process.whereis(name) do
      nil -> {:error, :not_found}
      pid ->
        DynamicSupervisor.terminate_child(RaftEx.NodeSupervisor, pid)
    end
  end

  @doc """
  Set a key-value pair in the replicated state machine. (§8)

  Routes to the leader. Returns `{:ok, value}` when committed.
  Returns `{:error, {:redirect, leader_id}}` if this node is not the leader.
  """
  @spec set(atom(), term(), term()) :: {:ok, term()} | {:error, term()}
  def set(node_id, key, value) do
    case Server.command(node_id, {:set, key, value}) do
      {:ok, {:ok, v}} -> {:ok, v}
      {:error, {:redirect, leader_id}} when leader_id != nil ->
        set(leader_id, key, value)
      other -> other
    end
  end

  @doc """
  Get a value from the replicated state machine. (§8)

  Note: reads go through the leader to ensure linearizability.
  Returns `{:ok, value}` or `{:ok, nil}` if key not found.
  """
  @spec get(atom(), term()) :: {:ok, term()} | {:error, term()}
  def get(node_id, key) do
    case Server.command(node_id, {:get, key}) do
      {:ok, {:ok, v}} -> {:ok, v}
      other -> other
    end
  end

  @doc """
  Delete a key from the replicated state machine. (§8)

  Returns `:ok` when committed.
  """
  @spec delete(atom(), term()) :: :ok | {:error, term()}
  def delete(node_id, key) do
    case Server.command(node_id, {:delete, key}) do
      {:ok, :ok} -> :ok
      other -> other
    end
  end

  @doc """
  Get the current status of a node (role, term, commitIndex, etc.).
  """
  @spec status(atom()) :: map()
  def status(node_id) do
    Server.status(node_id)
  end

  @doc """
  Find the current leader by querying all nodes in the cluster.
  Returns the leader node_id or nil if no leader yet.
  """
  @spec find_leader([atom()]) :: atom() | nil
  def find_leader(cluster) do
    Enum.find_value(cluster, fn node_id ->
      try do
        status = Server.status(node_id)
        if status.role == :leader, do: node_id, else: nil
      catch
        _, _ -> nil
      end
    end)
  end

  @doc """
  Add a node to the cluster using joint consensus (§6).

  Submits a `{:config_change, new_cluster}` entry to the leader.
  The cluster transitions through C_old,new → C_new safely.
  The new node must already be started with `start_node/2`.
  """
  @spec add_node(atom(), atom(), [atom()]) :: {:ok, term()} | {:error, term()}
  def add_node(_any_node, new_node, current_cluster) do
    new_cluster = Enum.uniq(current_cluster ++ [new_node])
    leader = find_leader(current_cluster)
    if leader == nil do
      {:error, :no_leader}
    else
      case Server.command(leader, {:config_change, new_cluster}) do
        {:ok, _} -> {:ok, new_cluster}
        other -> other
      end
    end
  end

  @doc """
  Remove a node from the cluster using joint consensus (§6).

  Submits a `{:config_change, new_cluster}` entry to the leader.
  """
  @spec remove_node(atom(), atom(), [atom()]) :: {:ok, term()} | {:error, term()}
  def remove_node(_any_node, node_to_remove, current_cluster) do
    new_cluster = Enum.reject(current_cluster, &(&1 == node_to_remove))
    leader = find_leader(current_cluster)
    if leader == nil do
      {:error, :no_leader}
    else
      case Server.command(leader, {:config_change, new_cluster}) do
        {:ok, _} -> {:ok, new_cluster}
        other -> other
      end
    end
  end

  @doc """
  Submit a command to the cluster, auto-routing to the leader. (§8)

  Tries each node until it finds the leader. Retries up to `retries` times
  with a short delay between attempts.
  """
  @spec command([atom()], term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def command(cluster, cmd, retries \\ 5) do
    do_command(cluster, cmd, retries)
  end

  defp do_command(_cluster, _cmd, 0), do: {:error, :no_leader}

  defp do_command(cluster, cmd, retries) do
    node = Enum.random(cluster)
    case Server.command(node, cmd) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:redirect, leader_id}} when leader_id != nil ->
        # §8: redirect to known leader
        Server.command(leader_id, cmd)

      {:error, _} ->
        Process.sleep(100)
        do_command(cluster, cmd, retries - 1)
    end
  end
end
