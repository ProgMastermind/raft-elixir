defmodule RaftEx.Cluster do
  @moduledoc """
  Peer list management and quorum math for Raft. (§5.2, §5.3, §6)

  Provides helpers for computing majorities, checking quorum, and
  determining the commit index from a set of matchIndex values.

  ## Quorum (§5.2, §5.3)

  Raft requires a majority (quorum) of servers to agree before:
  - A candidate wins an election (§5.2)
  - A log entry is considered committed (§5.3)

  For a cluster of N servers, majority = floor(N/2) + 1.

  ## Joint Consensus (§6)

  During a cluster membership change, the cluster is in a "joint" state
  where decisions require majorities from BOTH the old and new config.
  This prevents split-brain during the transition.

  ## Usage

      cluster = [:n1, :n2, :n3]
      peers = RaftEx.Cluster.peers(cluster, :n1)  # [:n2, :n3]
      2 = RaftEx.Cluster.majority(3)
      true = RaftEx.Cluster.has_majority?(2, 3)
      4 = RaftEx.Cluster.quorum_match_index([5, 4, 3], nil)
  """

  @doc """
  Return all peers in the cluster excluding `self_id`.
  """
  @spec peers([atom()], atom()) :: [atom()]
  def peers(cluster, self_id) do
    Enum.reject(cluster, &(&1 == self_id))
  end

  @doc """
  Return all peers from both old and new config during joint consensus (§6).
  Deduplicates so we don't send duplicate RPCs.
  """
  @spec joint_peers([atom()], [atom()], atom()) :: [atom()]
  def joint_peers(old_cluster, new_cluster, self_id) do
    (old_cluster ++ new_cluster)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == self_id))
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
  §6 — Joint consensus vote check.

  During a membership change, a candidate must win a majority from BOTH
  the old cluster AND the new cluster. Returns true only if both majorities
  are satisfied.

  If `joint_config` is nil, falls back to normal majority check.
  """
  @spec has_joint_majority?(MapSet.t(), [atom()], {[atom()], [atom()]} | nil) :: boolean()
  def has_joint_majority?(votes_received, current_cluster, joint_config) do
    case joint_config do
      nil ->
        # Normal single-config majority
        has_majority?(MapSet.size(votes_received), length(current_cluster))

      {old_cluster, new_cluster} ->
        # §6: must have majority from BOTH old and new config
        old_votes = Enum.count(old_cluster, &MapSet.member?(votes_received, &1))
        new_votes = Enum.count(new_cluster, &MapSet.member?(votes_received, &1))
        has_majority?(old_votes, length(old_cluster)) and
          has_majority?(new_votes, length(new_cluster))
    end
  end

  @doc """
  Given a list of matchIndex values (one per server including leader),
  return the highest index N such that a majority of servers have
  matchIndex >= N. (§5.3, §5.4.2)

  For joint consensus (§6), requires majority from BOTH old and new config.

  ## Example

      # 3 nodes: [leader=5, n2=4, n3=3]
      # sorted desc: [5, 4, 3]
      # majority = 2, so index 1 (0-based) = 4
      quorum_match_index([5, 4, 3], nil) == 4
  """
  @spec quorum_match_index([non_neg_integer()]) :: non_neg_integer()
  def quorum_match_index(match_indices) do
    n = length(match_indices)
    maj = majority(n)

    match_indices
    |> Enum.sort(:desc)
    |> Enum.at(maj - 1)
  end

  @doc """
  §6 — Joint consensus commit index.

  During a membership change, the commit index must satisfy a majority
  from BOTH old and new config. Returns the highest N satisfying both.

  `match_map` is %{node_id => match_index} for all known nodes.
  """
  @spec joint_quorum_match_index(map(), atom(), {[atom()], [atom()]} | nil) :: non_neg_integer()
  def joint_quorum_match_index(match_map, self_id, joint_config) do
    case joint_config do
      nil ->
        # Normal: use all values in match_map + self
        all_indices = Map.values(match_map)
        quorum_match_index(all_indices)

      {old_cluster, new_cluster} ->
        # §6: find highest N where majority of old AND majority of new have matchIndex >= N
        # Get match indices for each config
        old_indices = Enum.map(old_cluster, fn n ->
          if n == self_id, do: :infinity, else: Map.get(match_map, n, 0)
        end) |> Enum.map(fn x -> if x == :infinity, do: 999_999_999, else: x end)

        new_indices = Enum.map(new_cluster, fn n ->
          if n == self_id, do: :infinity, else: Map.get(match_map, n, 0)
        end) |> Enum.map(fn x -> if x == :infinity, do: 999_999_999, else: x end)

        min(quorum_match_index(old_indices), quorum_match_index(new_indices))
    end
  end
end
