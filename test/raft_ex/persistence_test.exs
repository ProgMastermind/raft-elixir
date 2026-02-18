defmodule RaftEx.PersistenceTest do
  use ExUnit.Case, async: false

  # Each test uses a unique node_id to avoid DETS table collisions
  setup context do
    node_id = :"persist_#{:erlang.phash2(context.test, 99_999)}"

    on_exit(fn ->
      RaftEx.Persistence.close(node_id)
      tmp = System.tmp_dir!()
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_meta.dets"))
    end)

    {:ok, _} = RaftEx.Persistence.open(node_id)
    {:ok, node_id: node_id}
  end

  # ---------------------------------------------------------------------------
  # §5.1 — currentTerm persistence
  # ---------------------------------------------------------------------------

  describe "currentTerm (§5.1)" do
    test "load_term returns 0 on first boot (uninitialized)", %{node_id: node_id} do
      # §5.1: initialized to 0 on first boot, increases monotonically
      assert RaftEx.Persistence.load_term(node_id) == 0
    end

    test "save_term persists the term", %{node_id: node_id} do
      RaftEx.Persistence.save_term(node_id, 5)
      assert RaftEx.Persistence.load_term(node_id) == 5
    end

    test "save_term overwrites previous term", %{node_id: node_id} do
      RaftEx.Persistence.save_term(node_id, 3)
      RaftEx.Persistence.save_term(node_id, 7)
      assert RaftEx.Persistence.load_term(node_id) == 7
    end

    test "currentTerm survives close and reopen (crash recovery)", %{node_id: node_id} do
      # §5.1: must survive restarts
      RaftEx.Persistence.save_term(node_id, 42)
      RaftEx.Persistence.close(node_id)

      {:ok, _} = RaftEx.Persistence.open(node_id)
      assert RaftEx.Persistence.load_term(node_id) == 42
    end
  end

  # ---------------------------------------------------------------------------
  # §5.1 — votedFor persistence
  # ---------------------------------------------------------------------------

  describe "votedFor (§5.1)" do
    test "load_vote returns nil on first boot (no vote cast)", %{node_id: node_id} do
      # §5.1: null if none
      assert RaftEx.Persistence.load_vote(node_id) == nil
    end

    test "save_vote persists the candidate", %{node_id: node_id} do
      RaftEx.Persistence.save_vote(node_id, :candidate_1)
      assert RaftEx.Persistence.load_vote(node_id) == :candidate_1
    end

    test "votedFor survives close and reopen (crash recovery)", %{node_id: node_id} do
      # §5.1: must survive restarts
      RaftEx.Persistence.save_vote(node_id, :n2)
      RaftEx.Persistence.close(node_id)

      {:ok, _} = RaftEx.Persistence.open(node_id)
      assert RaftEx.Persistence.load_vote(node_id) == :n2
    end

    test "clear_vote resets votedFor to nil", %{node_id: node_id} do
      # §5.1: when term advances, vote is reset
      RaftEx.Persistence.save_vote(node_id, :some_candidate)
      RaftEx.Persistence.clear_vote(node_id)
      assert RaftEx.Persistence.load_vote(node_id) == nil
    end

    test "clear_vote survives close and reopen", %{node_id: node_id} do
      RaftEx.Persistence.save_vote(node_id, :n3)
      RaftEx.Persistence.clear_vote(node_id)
      RaftEx.Persistence.close(node_id)

      {:ok, _} = RaftEx.Persistence.open(node_id)
      assert RaftEx.Persistence.load_vote(node_id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # §5.1 — load_all convenience function
  # ---------------------------------------------------------------------------

  describe "load_all (§5.1)" do
    test "returns {0, nil} on first boot", %{node_id: node_id} do
      assert RaftEx.Persistence.load_all(node_id) == {0, nil}
    end

    test "returns {term, voted_for} after saves", %{node_id: node_id} do
      RaftEx.Persistence.save_term(node_id, 3)
      RaftEx.Persistence.save_vote(node_id, :n1)
      assert RaftEx.Persistence.load_all(node_id) == {3, :n1}
    end

    test "load_all survives close and reopen", %{node_id: node_id} do
      RaftEx.Persistence.save_term(node_id, 10)
      RaftEx.Persistence.save_vote(node_id, :n2)
      RaftEx.Persistence.close(node_id)

      {:ok, _} = RaftEx.Persistence.open(node_id)
      assert RaftEx.Persistence.load_all(node_id) == {10, :n2}
    end
  end
end
