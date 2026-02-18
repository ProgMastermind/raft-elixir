defmodule RaftEx.Cluster do
  @moduledoc """
  Peer list management and quorum math for Raft. (§5.2, §5.3)

  Provides helpers for computing majorities, checking quorum, and
  determining the commit index from a set of matchIndex values.

  ## Quorum (§5.2, §5.3)

  Raft requires a majority (quorum) of servers to agree before:
  - A candidate wins an election (§5.2)
  - A log entry is considered committed (§5.3)

  For a cluster of N servers, majority = floor(N/2) + 1.

  ## Usage

      cluster = [:n1, :n2, :n3]
      peers = RaftEx.Cluster.peers(cluster, :n1)  # [:n2, :n3]
      2 = RaftEx.Cluster.majority(3)
      true = RaftEx.Cluster.has_majority?(2, 3)
      4 = RaftEx.Cluster.quorum_match_index([5, 4, 3])
  """

  @doc """
  Return all peers in the cluster excluding `self_id`.
  """
  @spec peers([atom()], atom()) :: [atom()]
  def peers(cluster, self_id) do
    Enum.reject(cluster, &(&1 == self_id))
  end

  @doc """
  Return the total number of nodes in the cluster.
  """
  @spec size([atom()]) :: pos_integer()
  def size(cluster), do: length(cluster)

  @doc """
  Return the minimum number of votes needed for a majority. (§5.2)

  For N servers: majority = floor(N/2) + 1
  """
  @spec majority(pos_integer()) :: pos_integer()
  def majority(n), do: div(n, 2) + 1

  @doc """
  Return true if `votes` is enough for a majority in a cluster of `cluster_size`. (§5.2)
  """
  @spec has_majority?(non_neg_integer(), pos_integer()) :: boolean()
  def has_majority?(votes, cluster_size) do
    votes >= majority(cluster_size)
  end

  @doc """
  Given a list of matchIndex values (one per server including leader),
  return the highest index N such that a majority of servers have
  matchIndex >= N. (§5.3, §5.4.2)

  This is used by the leader to advance commitIndex:
  - Sort matchIndex values descending
  - The value at position (majority - 1) is the highest N that a
    majority of servers have replicated

  ## Example

      # 3 nodes: [leader=5, n2=4, n3=3]
      # sorted desc: [5, 4, 3]
      # majority = 2, so index 1 (0-based) = 4
      quorum_match_index([5, 4, 3]) == 4
  """
  @spec quorum_match_index([non_neg_integer()]) :: non_neg_integer()
  def quorum_match_index(match_indices) do
    n = length(match_indices)
    maj = majority(n)

    match_indices
    |> Enum.sort(:desc)
    |> Enum.at(maj - 1)
  end
end
