defmodule RaftEx.RPCTest do
  use ExUnit.Case, async: true

  alias RaftEx.RPC.{
    PreVote,
    PreVoteReply,
    RequestVote,
    RequestVoteReply,
    AppendEntries,
    AppendEntriesReply,
    InstallSnapshot,
    InstallSnapshotReply
  }

  # ---------------------------------------------------------------------------
  # PreVote structs
  # ---------------------------------------------------------------------------

  describe "PreVote (pre-election optimization)" do
    test "struct has all required fields" do
      rpc = %PreVote{
        term: 4,
        candidate_id: :n2,
        last_log_index: 8,
        last_log_term: 3
      }

      assert rpc.term == 4
      assert rpc.candidate_id == :n2
      assert rpc.last_log_index == 8
      assert rpc.last_log_term == 3
    end

    test "reply has term, grant flag, and sender" do
      reply = %PreVoteReply{term: 5, vote_granted: true, from: :n1}
      assert reply.term == 5
      assert reply.vote_granted == true
      assert reply.from == :n1
    end
  end

  # ---------------------------------------------------------------------------
  # §5.2, §5.4 — RequestVote struct
  # ---------------------------------------------------------------------------

  describe "RequestVote (§5.2, §5.4)" do
    test "struct has all required Figure 2 fields" do
      rpc = %RequestVote{
        term: 3,
        candidate_id: :n2,
        last_log_index: 5,
        last_log_term: 2
      }

      assert rpc.term == 3
      assert rpc.candidate_id == :n2
      assert rpc.last_log_index == 5
      assert rpc.last_log_term == 2
    end

    test "enforce_keys raises on missing fields" do
      assert_raise ArgumentError, fn ->
        struct!(RequestVote, term: 1, candidate_id: :n1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §5.2 — RequestVoteReply struct
  # ---------------------------------------------------------------------------

  describe "RequestVoteReply (§5.2)" do
    test "struct has all required fields" do
      reply = %RequestVoteReply{term: 3, vote_granted: true, from: :n1}
      assert reply.term == 3
      assert reply.vote_granted == true
      assert reply.from == :n1
    end

    test "vote_granted can be false" do
      reply = %RequestVoteReply{term: 5, vote_granted: false, from: :n3}
      assert reply.vote_granted == false
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3 — AppendEntries struct
  # ---------------------------------------------------------------------------

  describe "AppendEntries (§5.3)" do
    test "struct has all required Figure 2 fields" do
      rpc = %AppendEntries{
        term: 2,
        leader_id: :n1,
        prev_log_index: 4,
        prev_log_term: 1,
        entries: [{5, 2, {:set, "x", 1}}],
        leader_commit: 4
      }

      assert rpc.term == 2
      assert rpc.leader_id == :n1
      assert rpc.prev_log_index == 4
      assert rpc.prev_log_term == 1
      assert rpc.entries == [{5, 2, {:set, "x", 1}}]
      assert rpc.leader_commit == 4
    end

    test "heartbeat has empty entries list" do
      heartbeat = %AppendEntries{
        term: 1,
        leader_id: :n1,
        prev_log_index: 0,
        prev_log_term: 0,
        entries: [],
        leader_commit: 0
      }

      assert heartbeat.entries == []
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3 — AppendEntriesReply struct
  # ---------------------------------------------------------------------------

  describe "AppendEntriesReply (§5.3)" do
    test "success reply has match_index" do
      reply = %AppendEntriesReply{
        term: 2,
        success: true,
        from: :n2,
        match_index: 5
      }

      assert reply.success == true
      assert reply.match_index == 5
      assert reply.conflict_index == nil
      assert reply.conflict_term == nil
    end

    test "failure reply has conflict info for fast backtracking" do
      reply = %AppendEntriesReply{
        term: 2,
        success: false,
        from: :n3,
        conflict_index: 3,
        conflict_term: 1
      }

      assert reply.success == false
      assert reply.conflict_index == 3
      assert reply.conflict_term == 1
    end

    test "default match_index is 0" do
      reply = %AppendEntriesReply{term: 1, success: false, from: :n2}
      assert reply.match_index == 0
    end
  end

  # ---------------------------------------------------------------------------
  # §7 — InstallSnapshot struct
  # ---------------------------------------------------------------------------

  describe "InstallSnapshot (§7)" do
    test "struct has all 7 required fields from §7" do
      data = :erlang.term_to_binary(%{"x" => 42})

      snap = %InstallSnapshot{
        term: 3,
        leader_id: :n1,
        last_included_index: 50,
        last_included_term: 2,
        offset: 0,
        data: data,
        done: true
      }

      assert snap.term == 3
      assert snap.leader_id == :n1
      assert snap.last_included_index == 50
      assert snap.last_included_term == 2
      assert snap.offset == 0
      assert is_binary(snap.data)
      assert snap.done == true
    end

    test "enforce_keys raises on missing fields" do
      assert_raise ArgumentError, fn ->
        struct!(InstallSnapshot, term: 1, leader_id: :n1)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §7 — InstallSnapshotReply struct
  # ---------------------------------------------------------------------------

  describe "InstallSnapshotReply (§7)" do
    test "struct has term, from, and offset fields" do
      reply = %InstallSnapshotReply{term: 3, from: :n2, offset: 128}
      assert reply.term == 3
      assert reply.from == :n2
      assert reply.offset == 128
    end
  end
end
