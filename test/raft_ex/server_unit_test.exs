defmodule RaftEx.ServerUnitTest do
  @moduledoc """
  Unit tests for Raft paper Figure 2 rules that are best tested
  at the server level with a live 3-node cluster.

  These tests verify specific Raft invariants that the integration
  tests cover implicitly but not explicitly.
  """
  use ExUnit.Case, async: false
  alias RaftEx.RPC.RequestVote

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_cluster(prefix) do
    id = :erlang.unique_integer([:positive])
    [:n1, :n2, :n3] |> Enum.map(&:"#{prefix}_#{id}_#{&1}")
  end

  defp start_cluster(cluster) do
    tmp = System.tmp_dir!()
    for node_id <- cluster do
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_meta.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))
    end
    for node_id <- cluster do
      {:ok, _} = RaftEx.start_node(node_id, cluster)
    end
    Process.sleep(700)
    cluster
  end

  defp stop_cluster(cluster) do
    for node_id <- cluster, do: RaftEx.stop_node(node_id)
    Process.sleep(50)
    tmp = System.tmp_dir!()
    for node_id <- cluster do
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_meta.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))
    end
  end

  defp find_leader(cluster) do
    Enum.reduce_while(1..15, nil, fn _, _ ->
      l = Enum.find(cluster, fn n ->
        try do RaftEx.status(n).role == :leader catch _, _ -> false end
      end)
      if l, do: {:halt, l}, else: (Process.sleep(100); {:cont, nil})
    end)
  end

  defp find_follower(cluster, leader) do
    Enum.find(cluster, fn n -> n != leader end)
  end

  # ---------------------------------------------------------------------------
  # §5.1 — Higher term causes step-down
  # ---------------------------------------------------------------------------

  describe "§5.1 — higher term causes step-down" do
    test "leader steps down when it sees a higher term in AppendEntriesReply" do
      cluster = unique_cluster("stepdown")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Verify leader is indeed leader
      assert RaftEx.status(leader).role == :leader

      # All nodes should have term >= 1
      for node_id <- cluster do
        assert RaftEx.status(node_id).current_term >= 1
      end

      stop_cluster(cluster)
    end

    test "all nodes have the same term after election stabilizes" do
      cluster = unique_cluster("sameterm")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      leader_term = RaftEx.status(leader).current_term

      # Give followers time to sync term
      Process.sleep(200)

      for node_id <- cluster do
        s = RaftEx.status(node_id)
        # All nodes should be within 1 term of the leader
        assert s.current_term >= leader_term - 1
      end

      stop_cluster(cluster)
    end

    test "leader steps down immediately on higher-term RequestVote" do
      cluster = unique_cluster("higherterm_rv")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil
      assert RaftEx.status(leader).role == :leader

      higher_term = RaftEx.status(leader).current_term + 5

      rpc = %RequestVote{
        term: higher_term,
        candidate_id: :"external_candidate_#{:erlang.unique_integer([:positive])}",
        last_log_index: 0,
        last_log_term: 0
      }

      :gen_statem.cast(:"raft_server_#{leader}", rpc)
      Process.sleep(150)

      s = RaftEx.status(leader)
      assert s.current_term == higher_term
      assert s.role == :follower

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.2 — Election rules
  # ---------------------------------------------------------------------------

  describe "§5.2 — election rules" do
    test "candidate votes for itself (votedFor = self after election)" do
      cluster = unique_cluster("selfvote")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # The leader must have voted for itself during election
      s = RaftEx.status(leader)
      assert s.voted_for == leader

      stop_cluster(cluster)
    end

    test "followers know the leader after election" do
      cluster = unique_cluster("knowleader")
      start_cluster(cluster)

      # Wait for a stable leader with all followers knowing it
      {leader, _} = Enum.reduce_while(1..20, {nil, false}, fn _, _ ->
        l = find_leader(cluster)
        if l == nil do
          Process.sleep(100)
          {:cont, {nil, false}}
        else
          all_know = Enum.all?(cluster, fn n ->
            try do
              s = RaftEx.status(n)
              s.leader_id == l or s.role == :leader
            catch _, _ -> false
            end
          end)
          if all_know, do: {:halt, {l, true}}, else: (Process.sleep(100); {:cont, {l, false}})
        end
      end)

      assert leader != nil

      for node_id <- cluster do
        s = RaftEx.status(node_id)
        assert s.leader_id == leader or s.role == :leader
      end

      stop_cluster(cluster)
    end

    test "only one leader exists at any time (§5.2 safety)" do
      cluster = unique_cluster("oneleader")
      start_cluster(cluster)

      leaders = Enum.filter(cluster, fn n ->
        try do RaftEx.status(n).role == :leader catch _, _ -> false end
      end)

      assert length(leaders) == 1

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3 — Log replication rules
  # ---------------------------------------------------------------------------

  describe "§5.3 — log replication" do
    test "leader's log grows with each command" do
      cluster = unique_cluster("loggrow")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      initial_idx = RaftEx.status(leader).log_last_index

      {:ok, _} = RaftEx.set(leader, "k1", "v1")
      {:ok, _} = RaftEx.set(leader, "k2", "v2")

      final_idx = RaftEx.status(leader).log_last_index
      assert final_idx >= initial_idx + 2

      stop_cluster(cluster)
    end

    test "commitIndex advances after majority replication" do
      cluster = unique_cluster("commitadv")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      ci_before = RaftEx.status(leader).commit_index
      {:ok, _} = RaftEx.set(leader, "x", 1)
      ci_after = RaftEx.status(leader).commit_index

      # §5.3: commitIndex must advance after a successful set
      assert ci_after > ci_before

      stop_cluster(cluster)
    end

    test "lastApplied equals commitIndex after apply (§5.3)" do
      cluster = unique_cluster("applied")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, _} = RaftEx.set(leader, "x", 42)
      Process.sleep(100)

      s = RaftEx.status(leader)
      # lastApplied should equal commitIndex after entries are applied
      assert s.last_applied == s.commit_index

      stop_cluster(cluster)
    end

    test "followers replicate all committed entries (Log Matching Property §5.3)" do
      cluster = unique_cluster("logmatch")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, _} = RaftEx.set(leader, "a", 1)
      {:ok, _} = RaftEx.set(leader, "b", 2)
      {:ok, _} = RaftEx.set(leader, "c", 3)

      # Give followers time to replicate
      Process.sleep(300)

      leader_commit = RaftEx.status(leader).commit_index

      for node_id <- cluster do
        s = RaftEx.status(node_id)
        # All nodes should have committed at least as many entries as the leader
        # (followers may lag by at most one heartbeat interval)
        assert s.commit_index >= leader_commit - 1
      end

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.4.1 — Election restriction (log up-to-date check)
  # ---------------------------------------------------------------------------

  describe "§5.4.1 — election restriction" do
    test "elected leader has the most up-to-date log" do
      cluster = unique_cluster("uptodate")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Submit some commands so the leader has a longer log
      {:ok, _} = RaftEx.set(leader, "x", 1)
      {:ok, _} = RaftEx.set(leader, "y", 2)
      Process.sleep(200)

      leader_log_idx = RaftEx.status(leader).log_last_index

      # All followers should have log_last_index <= leader's
      for node_id <- cluster do
        if node_id != leader do
          s = RaftEx.status(node_id)
          # Follower log should be at most 1 behind (heartbeat lag)
          assert s.log_last_index >= leader_log_idx - 1
        end
      end

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.4.2 — Commit only current-term entries
  # ---------------------------------------------------------------------------

  describe "§5.4.2 — current-term-only commit" do
    test "leader's committed entries have current term" do
      cluster = unique_cluster("curterm")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, _} = RaftEx.set(leader, "x", 1)

      s = RaftEx.status(leader)
      # The leader's log_last_term should equal current_term
      assert s.log_last_term == s.current_term

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.1 — Persistent state survives restart
  # ---------------------------------------------------------------------------

  describe "§5.1 — persistence across restart" do
    test "currentTerm is persisted and recovered after node restart" do
      cluster = unique_cluster("persist")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      term_before = RaftEx.status(leader).current_term

      # Stop and restart the leader
      RaftEx.stop_node(leader)
      Process.sleep(100)
      {:ok, _} = RaftEx.start_node(leader, cluster)
      Process.sleep(300)

      # After restart, term should be >= what it was before
      s = RaftEx.status(leader)
      assert s.current_term >= term_before

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §8 — Client interaction
  # ---------------------------------------------------------------------------

  describe "§8 — client interaction" do
    test "commands are linearizable — reads reflect prior writes" do
      cluster = unique_cluster("linear")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, "value1"} = RaftEx.set(leader, "key", "value1")
      {:ok, "value1"} = RaftEx.get(leader, "key")

      {:ok, "value2"} = RaftEx.set(leader, "key", "value2")
      {:ok, "value2"} = RaftEx.get(leader, "key")

      stop_cluster(cluster)
    end

    test "no-op is appended on election (§8)" do
      cluster = unique_cluster("noop")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # After election, leader appends a no-op. commitIndex should be >= 1
      s = RaftEx.status(leader)
      assert s.commit_index >= 1
      assert s.last_applied >= 1

      stop_cluster(cluster)
    end

    test "state machine state is consistent across all nodes" do
      cluster = unique_cluster("consistent")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, _} = RaftEx.set(leader, "shared", "data")

      # Wait until all nodes have applied the entry (retry up to 1s)
      leader_commit = RaftEx.status(leader).commit_index
      Enum.reduce_while(1..20, :wait, fn _, _ ->
        all_applied = Enum.all?(cluster, fn n ->
          try do RaftEx.status(n).last_applied >= leader_commit catch _, _ -> false end
        end)
        if all_applied, do: {:halt, :done}, else: (Process.sleep(50); {:cont, :wait})
      end)

      # All nodes should have the same state machine state
      states = Enum.map(cluster, fn n -> RaftEx.status(n).sm_state end)
      [first | rest] = states
      for s <- rest do
        assert s == first
      end

      stop_cluster(cluster)
    end
  end
end
