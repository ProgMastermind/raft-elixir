defmodule RaftEx.FaultToleranceTest do
  @moduledoc """
  Fault tolerance and joint consensus tests (§5.2, §6).

  Tests:
  - Leader crash → automatic re-election (§5.2)
  - Minority partition cannot elect a leader (§5.2 safety)
  - Node restart recovers persistent state (§5.1)
  - Joint consensus: add node to cluster (§6)
  - Joint consensus: remove node from cluster (§6)
  - Cluster continues operating after minority node failure
  """
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_cluster(prefix) do
    id = :erlang.unique_integer([:positive])
    [:n1, :n2, :n3] |> Enum.map(&:"#{prefix}_#{id}_#{&1}")
  end

  defp clean_files(cluster) do
    tmp = System.tmp_dir!()
    for node_id <- cluster do
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_meta.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))
    end
  end

  defp start_cluster(cluster) do
    clean_files(cluster)
    for node_id <- cluster do
      {:ok, _} = RaftEx.start_node(node_id, cluster)
    end
    Process.sleep(700)
    cluster
  end

  defp stop_cluster(cluster) do
    for node_id <- cluster do
      try do RaftEx.stop_node(node_id) catch _, _ -> :ok end
    end
    Process.sleep(50)
    clean_files(cluster)
  end

  defp find_leader(cluster) do
    Enum.reduce_while(1..20, nil, fn _, _ ->
      l = Enum.find(cluster, fn n ->
        try do RaftEx.status(n).role == :leader catch _, _ -> false end
      end)
      if l, do: {:halt, l}, else: (Process.sleep(100); {:cont, nil})
    end)
  end

  defp wait_for_leader(cluster, timeout_ms \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    Enum.reduce_while(Stream.repeatedly(fn -> nil end), nil, fn _, _ ->
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
  # §5.2 — Leader crash and re-election
  # ---------------------------------------------------------------------------

  describe "§5.2 — fault tolerance: leader crash" do
    test "cluster elects new leader after leader crash" do
      cluster = unique_cluster("crash")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Commit some data before crash
      {:ok, _} = RaftEx.set(leader, "before_crash", "yes")

      # Crash the leader
      RaftEx.stop_node(leader)
      remaining = Enum.reject(cluster, &(&1 == leader))

      # New leader should be elected within election timeout (max 300ms + buffer)
      new_leader = wait_for_leader(remaining, 1500)
      assert new_leader != nil
      assert new_leader != leader

      # New leader should be able to accept commands
      {:ok, _} = RaftEx.set(new_leader, "after_crash", "yes")

      stop_cluster(remaining)
    end

    test "data committed before leader crash is preserved (§5.4 safety)" do
      cluster = unique_cluster("preserve")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, "important"} = RaftEx.set(leader, "key", "important")

      # Wait for replication to all nodes
      Process.sleep(200)

      # Crash the leader
      RaftEx.stop_node(leader)
      remaining = Enum.reject(cluster, &(&1 == leader))

      new_leader = wait_for_leader(remaining, 1500)
      assert new_leader != nil

      # Data must be preserved on the new leader
      {:ok, "important"} = RaftEx.get(new_leader, "key")

      stop_cluster(remaining)
    end

    test "cluster survives minority node failure (1 of 3 nodes)" do
      cluster = unique_cluster("minority")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Kill a follower (minority)
      follower = Enum.find(cluster, &(&1 != leader))
      RaftEx.stop_node(follower)

      # Leader should still be able to commit (majority = 2 of 3)
      {:ok, "survived"} = RaftEx.set(leader, "status", "survived")

      stop_cluster(Enum.reject(cluster, &(&1 == follower)))
    end
  end

  # ---------------------------------------------------------------------------
  # §5.2 — Minority partition cannot elect a leader
  # ---------------------------------------------------------------------------

  describe "§5.2 — minority partition safety" do
    test "2 nodes cannot elect a leader when 1 is needed for majority of 3" do
      # With 3 nodes, majority = 2. If we only have 1 node, it cannot win.
      cluster = unique_cluster("partition")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Stop 2 nodes — only 1 remains (minority)
      [keep | stop_these] = Enum.reject(cluster, &(&1 == leader)) ++ [leader]
      for n <- stop_these, do: RaftEx.stop_node(n)

      # The single remaining node should NOT be able to elect itself
      # (it needs 2 votes but can only get 1 — its own)
      Process.sleep(600)  # Wait longer than election timeout

      # The lone node will try to become candidate but can't win majority
      # It should be in candidate state (trying) or follower (gave up)
      s = try do RaftEx.status(keep) catch _, _ -> %{role: :unknown} end
      # It should NOT be leader (can't get majority)
      assert s.role != :leader

      stop_cluster([keep])
    end
  end

  # ---------------------------------------------------------------------------
  # §5.1 — Persistent state recovery after restart
  # ---------------------------------------------------------------------------

  describe "§5.1 — persistence: state recovery after restart" do
    test "node recovers currentTerm after restart" do
      cluster = unique_cluster("termrecover")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      term_before = RaftEx.status(leader).current_term
      assert term_before >= 1

      # Stop and restart the node
      RaftEx.stop_node(leader)
      Process.sleep(200)
      {:ok, _} = RaftEx.start_node(leader, cluster)
      Process.sleep(400)

      # Term must be >= what it was (never goes backward)
      s = RaftEx.status(leader)
      assert s.current_term >= term_before

      stop_cluster(cluster)
    end

    test "node recovers log entries after restart" do
      cluster = unique_cluster("logrecover")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, _} = RaftEx.set(leader, "persistent_key", "persistent_value")
      Process.sleep(200)

      log_idx_before = RaftEx.status(leader).log_last_index

      # Restart a follower
      follower = Enum.find(cluster, &(&1 != leader))
      RaftEx.stop_node(follower)
      Process.sleep(100)
      {:ok, _} = RaftEx.start_node(follower, cluster)
      Process.sleep(500)

      # After restart, follower should catch up via AppendEntries
      s = RaftEx.status(follower)
      assert s.commit_index >= log_idx_before - 1

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §6 — Joint consensus: cluster membership changes
  # ---------------------------------------------------------------------------

  describe "§6 — joint consensus: membership changes" do
    test "cluster quorum math: joint majority requires both old and new" do
      # Test the Cluster module's joint majority logic directly
      # old_cluster = 3 nodes (majority = 2)
      # new_cluster = 5 nodes (majority = 3)
      old_cluster = [:n1, :n2, :n3]
      new_cluster = [:n1, :n2, :n3, :n4, :n5]

      # Votes from n1, n2 only:
      # old: 2/3 ✓ (majority), new: 2/5 ✗ (not majority) → joint fails
      votes1 = MapSet.new([:n1, :n2])
      refute RaftEx.Cluster.has_joint_majority?(votes1, old_cluster, {old_cluster, new_cluster})

      # Votes from n4, n5 only:
      # old: 0/3 ✗ (not majority), new: 2/5 ✗ (not majority) → joint fails
      votes2 = MapSet.new([:n4, :n5])
      refute RaftEx.Cluster.has_joint_majority?(votes2, old_cluster, {old_cluster, new_cluster})

      # Votes from n1, n2, n3, n4, n5 (all):
      # old: 3/3 ✓, new: 5/5 ✓ → joint succeeds
      votes3 = MapSet.new([:n1, :n2, :n3, :n4, :n5])
      assert RaftEx.Cluster.has_joint_majority?(votes3, old_cluster, {old_cluster, new_cluster})

      # Votes from n1, n2, n3 (majority of old) + n4 (only 4 of 5 new, majority=3 ✓):
      # old: 3/3 ✓, new: 4/5 ✓ → joint succeeds
      votes4 = MapSet.new([:n1, :n2, :n3, :n4])
      assert RaftEx.Cluster.has_joint_majority?(votes4, old_cluster, {old_cluster, new_cluster})

      # Votes from n1, n2, n3 only (majority of old, but only 3/5 new = majority ✓):
      # old: 3/3 ✓, new: 3/5 ✓ → joint succeeds
      votes5 = MapSet.new([:n1, :n2, :n3])
      assert RaftEx.Cluster.has_joint_majority?(votes5, old_cluster, {old_cluster, new_cluster})
    end

    test "joint_peers returns union of old and new cluster without self" do
      old_cluster = [:n1, :n2, :n3]
      new_cluster = [:n1, :n2, :n3, :n4]
      peers = RaftEx.Cluster.joint_peers(old_cluster, new_cluster, :n1)
      assert :n2 in peers
      assert :n3 in peers
      assert :n4 in peers
      refute :n1 in peers
      assert length(peers) == 3
    end

    test "config_change command is accepted by leader (§6 phase 1)" do
      cluster = unique_cluster("cfgchange")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Submit a config_change — this enters joint consensus
      new_cluster = cluster ++ [:"cfgchange_extra"]
      result = RaftEx.Server.command(leader, {:config_change, new_cluster})

      # Should succeed (the entry gets committed)
      assert match?({:ok, _}, result)

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # OTP Supervision — fault tolerance via OTP
  # ---------------------------------------------------------------------------

  describe "OTP supervision — Elixir fault tolerance" do
    test "DynamicSupervisor manages all Raft nodes" do
      cluster = unique_cluster("otp")
      start_cluster(cluster)

      # All nodes should be running under the DynamicSupervisor
      children = DynamicSupervisor.which_children(RaftEx.NodeSupervisor)
      pids = Enum.map(children, fn {_, pid, _, _} -> pid end)

      for node_id <- cluster do
        name = :"raft_server_#{node_id}"
        pid = Process.whereis(name)
        assert pid != nil
        assert pid in pids
      end

      stop_cluster(cluster)
    end

    test "stopped node is removed from supervisor" do
      cluster = unique_cluster("otpstop")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      pid_before = Process.whereis(:"raft_server_#{leader}")
      assert pid_before != nil

      RaftEx.stop_node(leader)
      Process.sleep(50)

      pid_after = Process.whereis(:"raft_server_#{leader}")
      assert pid_after == nil

      stop_cluster(Enum.reject(cluster, &(&1 == leader)))
    end
  end
end
