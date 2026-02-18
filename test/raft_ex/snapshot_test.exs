defmodule RaftEx.SnapshotTest do
  use ExUnit.Case, async: false

  setup context do
    node_id = :"snap_#{:erlang.phash2(context.test, 99_999)}"
    tmp = System.tmp_dir!()

    # Clean up any leftover files
    File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
    File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))

    {:ok, _} = RaftEx.Log.open(node_id)

    on_exit(fn ->
      RaftEx.Log.close(node_id)
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))
    end)

    {:ok, node_id: node_id, tmp: tmp}
  end

  # ---------------------------------------------------------------------------
  # §7 — Snapshot creation
  # ---------------------------------------------------------------------------

  describe "create/5 (§7)" do
    test "creates snapshot file and discards log entries up to last_included_index", %{
      node_id: node_id
    } do
      # Append 5 log entries
      for i <- 1..5, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})
      assert RaftEx.Log.last_index(node_id) == 5

      sm_state = %{"k1" => 1, "k2" => 2, "k3" => 3}
      cluster = [:n1, :n2, :n3]

      # Snapshot at index 3
      {:ok, snapshot} = RaftEx.Snapshot.create(node_id, 3, 1, sm_state, cluster)

      assert snapshot.last_included_index == 3
      assert snapshot.last_included_term == 1
      assert snapshot.cluster == cluster
      assert is_binary(snapshot.data)

      # §7: log entries 1..3 discarded; 4 and 5 remain
      assert RaftEx.Log.get(node_id, 1) == nil
      assert RaftEx.Log.get(node_id, 2) == nil
      assert RaftEx.Log.get(node_id, 3) == nil
      assert RaftEx.Log.get(node_id, 4) != nil
      assert RaftEx.Log.get(node_id, 5) != nil
    end
  end

  # ---------------------------------------------------------------------------
  # §7 — Snapshot load
  # ---------------------------------------------------------------------------

  describe "load/1 (§7)" do
    test "load returns nil when no snapshot exists", %{node_id: node_id} do
      assert RaftEx.Snapshot.load(node_id) == nil
    end

    test "load returns the snapshot after create", %{node_id: node_id} do
      sm_state = %{"x" => 42}
      {:ok, _} = RaftEx.Snapshot.create(node_id, 1, 1, sm_state, [:n1, :n2, :n3])

      loaded = RaftEx.Snapshot.load(node_id)
      assert loaded != nil
      assert loaded.last_included_index == 1
      assert loaded.last_included_term == 1

      # Deserialize and verify state machine data
      restored = RaftEx.StateMachine.deserialize(loaded.data)
      assert restored == sm_state
    end
  end

  # ---------------------------------------------------------------------------
  # §7 — Snapshot install (lagging follower)
  # ---------------------------------------------------------------------------

  describe "install/2 (§7)" do
    test "install replaces log and restores state machine", %{node_id: node_id} do
      # Follower has some stale log entries
      for i <- 1..3, do: RaftEx.Log.append(node_id, 1, {:set, "old#{i}", i})
      assert RaftEx.Log.last_index(node_id) == 3

      # Leader sends snapshot covering indices 1..10
      sm_state = %{"a" => 100, "b" => 200}

      snapshot = %{
        last_included_index: 10,
        last_included_term: 2,
        cluster: [:n1, :n2, :n3],
        data: RaftEx.StateMachine.serialize(sm_state)
      }

      {:ok, restored_state} = RaftEx.Snapshot.install(node_id, snapshot)

      # State machine restored correctly
      assert restored_state == sm_state

      # §7: all log entries up to last_included_index discarded
      assert RaftEx.Log.get(node_id, 1) == nil
      assert RaftEx.Log.get(node_id, 2) == nil
      assert RaftEx.Log.get(node_id, 3) == nil

      # Snapshot persisted to disk
      loaded = RaftEx.Snapshot.load(node_id)
      assert loaded.last_included_index == 10
      assert loaded.last_included_term == 2
    end
  end

  # ---------------------------------------------------------------------------
  # §7 — should_snapshot?
  # ---------------------------------------------------------------------------

  describe "should_snapshot? (§7)" do
    test "returns false when log is below threshold", %{node_id: node_id} do
      for i <- 1..5, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})
      assert RaftEx.Snapshot.should_snapshot?(node_id) == false
    end

    test "threshold returns 100" do
      assert RaftEx.Snapshot.threshold() == 100
    end
  end
end
