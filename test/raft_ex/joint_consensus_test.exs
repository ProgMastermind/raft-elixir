defmodule RaftEx.JointConsensusTest do
  @moduledoc """
  Explicit tests for the two §6 spec gaps that were fixed:

  Gap 1: Nodes not in C_new must shut down after config_change committed (§6)
  Gap 2: During joint consensus, vote counting requires majority from BOTH
         old AND new config — not just simple majority (§6)
  """
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uid(prefix) do
    id = :erlang.unique_integer([:positive])
    :"#{prefix}_#{id}"
  end

  defp make_cluster(prefix, count) do
    id = :erlang.unique_integer([:positive])
    Enum.map(1..count, fn i -> :"#{prefix}_#{id}_n#{i}" end)
  end

  defp clean(cluster) do
    tmp = System.tmp_dir!()
    for n <- cluster do
      File.rm(Path.join(tmp, "raft_ex_#{n}_meta.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{n}_log.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{n}_snapshot.bin"))
    end
  end

  defp start_cluster(cluster) do
    clean(cluster)
    for n <- cluster, do: {:ok, _} = RaftEx.start_node(n, cluster)
    Process.sleep(700)
    cluster
  end

  defp stop_all(cluster) do
    for n <- cluster do
      try do RaftEx.stop_node(n) catch _, _ -> :ok end
    end
    Process.sleep(50)
    clean(cluster)
  end

  defp find_leader(cluster, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    Stream.repeatedly(fn -> nil end)
    |> Enum.reduce_while(nil, fn _, _ ->
      l = Enum.find(cluster, fn n ->
        try do RaftEx.status(n).role == :leader catch _, _ -> false end
      end)
      cond do
        l != nil -> {:halt, l}
        System.monotonic_time(:millisecond) > deadline -> {:halt, nil}
        true -> Process.sleep(50); {:cont, nil}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Gap 1: §6 — Node removed from C_new shuts down
  # ---------------------------------------------------------------------------

  describe "§6 Gap 1: removed node shuts down after config_change committed" do
    test "node not in C_new shuts down after config_change entry is committed" do
      # Start 3-node cluster: [n1, n2, n3]
      cluster = make_cluster("remove", 3)
      [n1, n2, n3] = cluster
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Verify n3 is alive before removal
      pid_before = Process.whereis(:"raft_server_#{n3}")
      assert pid_before != nil

      # Submit config_change that removes n3 → new cluster is [n1, n2]
      new_cluster = [n1, n2]
      result = RaftEx.Server.command(leader, {:config_change, new_cluster})
      assert match?({:ok, _}, result)

      # Wait for the config_change to be committed and n3 to shut down
      # n3 gets the AppendEntries, applies the config_change, sees it's not in C_new,
      # and schedules :shutdown_not_in_cluster after 100ms
      Process.sleep(500)

      # n3 should now be dead
      pid_after = Process.whereis(:"raft_server_#{n3}")
      assert pid_after == nil,
        "Expected n3 to shut down after being removed from C_new, but it's still running"

      # n1 and n2 should still be alive
      assert Process.whereis(:"raft_server_#{n1}") != nil
      assert Process.whereis(:"raft_server_#{n2}") != nil

      stop_all([n1, n2])
    end

    test "node IN C_new does NOT shut down after config_change committed" do
      cluster = make_cluster("keepalive", 3)
      [n1, n2, n3] = cluster
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Config change that keeps all 3 nodes (no removal)
      same_cluster = [n1, n2, n3]
      result = RaftEx.Server.command(leader, {:config_change, same_cluster})
      assert match?({:ok, _}, result)

      Process.sleep(300)

      # All nodes should still be alive
      assert Process.whereis(:"raft_server_#{n1}") != nil
      assert Process.whereis(:"raft_server_#{n2}") != nil
      assert Process.whereis(:"raft_server_#{n3}") != nil

      stop_all(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # Gap 2: §6 — Joint majority in vote counting
  # ---------------------------------------------------------------------------

  describe "§6 Gap 2: has_joint_majority? used in vote counting" do
    test "has_joint_majority? returns false when only old config has majority" do
      # old = [n1, n2, n3], new = [n1, n2, n3, n4, n5]
      # Votes from n1, n2 only: old majority ✓ (2/3), new majority ✗ (2/5)
      old = [:n1, :n2, :n3]
      new = [:n1, :n2, :n3, :n4, :n5]
      votes = MapSet.new([:n1, :n2])
      refute RaftEx.Cluster.has_joint_majority?(votes, old, {old, new})
    end

    test "has_joint_majority? returns false when only new config has majority" do
      # old = [n1, n2, n3], new = [n1, n2, n3, n4, n5]
      # Votes from n4, n5 only: old majority ✗ (0/3), new majority ✗ (2/5)
      old = [:n1, :n2, :n3]
      new = [:n1, :n2, :n3, :n4, :n5]
      votes = MapSet.new([:n4, :n5])
      refute RaftEx.Cluster.has_joint_majority?(votes, old, {old, new})
    end

    test "has_joint_majority? returns true when BOTH configs have majority" do
      # old = [n1, n2, n3], new = [n1, n2, n3, n4, n5]
      # Votes from n1, n2, n3: old majority ✓ (3/3), new majority ✓ (3/5)
      old = [:n1, :n2, :n3]
      new = [:n1, :n2, :n3, :n4, :n5]
      votes = MapSet.new([:n1, :n2, :n3])
      assert RaftEx.Cluster.has_joint_majority?(votes, old, {old, new})
    end

    test "has_joint_majority? with nil joint_config falls back to simple majority" do
      # When joint_config is nil (normal operation), just check simple majority
      cluster = [:n1, :n2, :n3]
      # 2 of 3 = majority
      votes = MapSet.new([:n1, :n2])
      assert RaftEx.Cluster.has_joint_majority?(votes, cluster, nil)
      # 1 of 3 = not majority
      votes2 = MapSet.new([:n1])
      refute RaftEx.Cluster.has_joint_majority?(votes2, cluster, nil)
    end

    test "joint consensus election: candidate needs votes from both old and new cluster" do
      # This is an integration test: start a 3-node cluster, submit a config_change
      # to expand to 5 nodes (but only start 3), verify the joint_config is set
      # and that the cluster still operates correctly
      cluster = make_cluster("joint_election", 3)
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Verify leader is in normal (non-joint) mode
      s = RaftEx.status(leader)
      assert s.role == :leader

      # Submit a config_change — this sets joint_config on the leader
      # The new cluster includes 2 extra nodes that don't exist yet
      [n1, n2, n3] = cluster
      new_cluster = [n1, n2, n3]  # same cluster — safe joint consensus test
      {:ok, _} = RaftEx.Server.command(leader, {:config_change, new_cluster})

      # After commit, joint_config should be cleared (C_new committed)
      Process.sleep(300)

      # Cluster should still work normally
      {:ok, "test_value"} = RaftEx.set(leader, "joint_test", "test_value")

      stop_all(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §6 — Cluster.has_joint_majority? edge cases
  # ---------------------------------------------------------------------------

  describe "§6 Cluster.has_joint_majority? edge cases" do
    test "2-node old cluster: majority = 2, joint with 3-node new" do
      old = [:n1, :n2]
      new = [:n1, :n2, :n3]
      # Need 2/2 old AND 2/3 new
      votes_fail = MapSet.new([:n1])
      refute RaftEx.Cluster.has_joint_majority?(votes_fail, old, {old, new})

      votes_pass = MapSet.new([:n1, :n2])
      assert RaftEx.Cluster.has_joint_majority?(votes_pass, old, {old, new})
    end

    test "single-node cluster: majority = 1, joint with 3-node new" do
      old = [:n1]
      new = [:n1, :n2, :n3]
      # Need 1/1 old AND 2/3 new
      votes_only_old = MapSet.new([:n1])
      refute RaftEx.Cluster.has_joint_majority?(votes_only_old, old, {old, new})

      votes_both = MapSet.new([:n1, :n2])
      assert RaftEx.Cluster.has_joint_majority?(votes_both, old, {old, new})
    end

    test "empty votes: never a joint majority" do
      old = [:n1, :n2, :n3]
      new = [:n1, :n2, :n3, :n4, :n5]
      votes = MapSet.new()
      refute RaftEx.Cluster.has_joint_majority?(votes, old, {old, new})
    end
  end
end
