defmodule RaftEx.LogTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  setup context do
    node_id = :"log_#{:erlang.phash2(context.test, 99_999)}"
    tmp = System.tmp_dir!()
    File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
    {:ok, _} = RaftEx.Log.open(node_id)

    on_exit(fn ->
      RaftEx.Log.close(node_id)
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
    end)

    {:ok, node_id: node_id}
  end

  # ---------------------------------------------------------------------------
  # §5.3 — Basic log invariants
  # ---------------------------------------------------------------------------

  describe "empty log (§5.3)" do
    test "last_index returns 0 for empty log", %{node_id: node_id} do
      assert RaftEx.Log.last_index(node_id) == 0
    end

    test "last_term returns 0 for empty log", %{node_id: node_id} do
      assert RaftEx.Log.last_term(node_id) == 0
    end

    test "length returns 0 for empty log", %{node_id: node_id} do
      assert RaftEx.Log.length(node_id) == 0
    end

    test "term_at returns 0 for index 0 (base case)", %{node_id: node_id} do
      # §5.3: index 0 is the base case before the log starts
      assert RaftEx.Log.term_at(node_id, 0) == 0
    end

    test "has_entry? returns true for index=0, term=0 (empty log base case)", %{node_id: _} do
      # §5.3: prevLogIndex=0, prevLogTerm=0 always matches (empty log)
      assert RaftEx.Log.has_entry?(:any_node, 0, 0) == true
    end
  end

  describe "append (§5.3)" do
    test "append returns sequential 1-based indices", %{node_id: node_id} do
      {:ok, 1} = RaftEx.Log.append(node_id, 1, {:set, "a", 1})
      {:ok, 2} = RaftEx.Log.append(node_id, 1, {:set, "b", 2})
      {:ok, 3} = RaftEx.Log.append(node_id, 2, {:set, "c", 3})

      assert RaftEx.Log.last_index(node_id) == 3
      assert RaftEx.Log.last_term(node_id) == 2
      assert RaftEx.Log.length(node_id) == 3
    end

    test "get returns the correct entry", %{node_id: node_id} do
      {:ok, 1} = RaftEx.Log.append(node_id, 5, {:set, "x", 42})
      assert {1, 5, {:set, "x", 42}} = RaftEx.Log.get(node_id, 1)
    end

    test "get returns nil for missing index", %{node_id: node_id} do
      assert RaftEx.Log.get(node_id, 99) == nil
    end

    test "term_at returns correct term for existing entry", %{node_id: node_id} do
      RaftEx.Log.append(node_id, 3, {:noop})
      assert RaftEx.Log.term_at(node_id, 1) == 3
    end

    test "has_entry? returns true for matching index+term", %{node_id: node_id} do
      RaftEx.Log.append(node_id, 3, {:noop})
      assert RaftEx.Log.has_entry?(node_id, 1, 3) == true
      assert RaftEx.Log.has_entry?(node_id, 1, 99) == false
    end
  end

  describe "get_range and get_from (§5.3)" do
    test "get_range returns sorted entries in range", %{node_id: node_id} do
      for i <- 1..5, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})

      entries = RaftEx.Log.get_range(node_id, 2, 4)
      assert length(entries) == 3
      assert Enum.map(entries, fn {idx, _, _} -> idx end) == [2, 3, 4]
    end

    test "get_from returns all entries from index onward", %{node_id: node_id} do
      for i <- 1..5, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})

      entries = RaftEx.Log.get_from(node_id, 3)
      assert length(entries) == 3
      assert Enum.map(entries, fn {idx, _, _} -> idx end) == [3, 4, 5]
    end
  end

  describe "truncate_from (§5.3)" do
    test "truncate_from removes entries from index onward", %{node_id: node_id} do
      for i <- 1..5, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})
      assert RaftEx.Log.last_index(node_id) == 5

      RaftEx.Log.truncate_from(node_id, 3)

      assert RaftEx.Log.last_index(node_id) == 2
      assert RaftEx.Log.get(node_id, 1) != nil
      assert RaftEx.Log.get(node_id, 2) != nil
      assert RaftEx.Log.get(node_id, 3) == nil
      assert RaftEx.Log.get(node_id, 4) == nil
      assert RaftEx.Log.get(node_id, 5) == nil
    end

    test "truncate_from index 1 clears entire log", %{node_id: node_id} do
      for i <- 1..3, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})
      RaftEx.Log.truncate_from(node_id, 1)
      assert RaftEx.Log.last_index(node_id) == 0
    end
  end

  describe "truncate_up_to (§7)" do
    test "truncate_up_to removes entries 1..n (log compaction)", %{node_id: node_id} do
      for i <- 1..5, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})

      RaftEx.Log.truncate_up_to(node_id, 3)

      assert RaftEx.Log.get(node_id, 1) == nil
      assert RaftEx.Log.get(node_id, 2) == nil
      assert RaftEx.Log.get(node_id, 3) == nil
      assert RaftEx.Log.get(node_id, 4) != nil
      assert RaftEx.Log.get(node_id, 5) != nil
    end

    test "truncate_up_to 0 is a no-op", %{node_id: node_id} do
      RaftEx.Log.append(node_id, 1, {:set, "x", 1})
      RaftEx.Log.truncate_up_to(node_id, 0)
      assert RaftEx.Log.get(node_id, 1) != nil
    end
  end

  describe "append_entries — idempotency (§5.3)" do
    test "same entries sent twice are not re-inserted", %{node_id: node_id} do
      entries = [{1, 1, {:set, "a", 1}}, {2, 1, {:set, "b", 2}}, {3, 1, {:set, "c", 3}}]
      :ok = RaftEx.Log.append_entries(node_id, 0, entries)
      assert RaftEx.Log.last_index(node_id) == 3

      # Send same entries again — must be a no-op
      :ok = RaftEx.Log.append_entries(node_id, 0, entries)
      assert RaftEx.Log.last_index(node_id) == 3

      assert {1, 1, {:set, "a", 1}} = RaftEx.Log.get(node_id, 1)
      assert {2, 1, {:set, "b", 2}} = RaftEx.Log.get(node_id, 2)
      assert {3, 1, {:set, "c", 3}} = RaftEx.Log.get(node_id, 3)
    end
  end

  describe "append_entries — conflict detection (§5.3)" do
    test "conflicting entry (different term) triggers truncation and replacement", %{
      node_id: node_id
    } do
      # Append 3 entries at term 1
      :ok =
        RaftEx.Log.append_entries(node_id, 0, [
          {1, 1, {:set, "a", 1}},
          {2, 1, {:set, "b", 2}},
          {3, 1, {:set, "c", 3}}
        ])

      assert RaftEx.Log.last_index(node_id) == 3

      # Leader sends conflicting entry at index 2 with term 2
      :ok =
        RaftEx.Log.append_entries(node_id, 1, [
          {2, 2, {:set, "b", 99}},
          {3, 2, {:set, "d", 4}}
        ])

      # Index 1 unchanged; index 2 and 3 replaced
      assert {1, 1, {:set, "a", 1}} = RaftEx.Log.get(node_id, 1)
      assert {2, 2, {:set, "b", 99}} = RaftEx.Log.get(node_id, 2)
      assert {3, 2, {:set, "d", 4}} = RaftEx.Log.get(node_id, 3)
      assert RaftEx.Log.last_index(node_id) == 3
    end
  end

  describe "first_index_for_term (§5.3 fast backtracking)" do
    test "returns first index with given term", %{node_id: node_id} do
      RaftEx.Log.append(node_id, 1, {:set, "a", 1})
      RaftEx.Log.append(node_id, 1, {:set, "b", 2})
      RaftEx.Log.append(node_id, 2, {:set, "c", 3})
      RaftEx.Log.append(node_id, 2, {:set, "d", 4})

      assert RaftEx.Log.first_index_for_term(node_id, 1) == 1
      assert RaftEx.Log.first_index_for_term(node_id, 2) == 3
      assert RaftEx.Log.first_index_for_term(node_id, 99) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # StreamData property tests — §5.3 log invariants
  # ---------------------------------------------------------------------------

  describe "property-based log invariants (§5.3)" do
    property "append always produces sequential 1-based indices" do
      check all(
              n <- StreamData.integer(1..20),
              term <- StreamData.integer(1..10)
            ) do
        node_id = :"prop_seq_#{:erlang.unique_integer([:positive])}"
        tmp = System.tmp_dir!()
        File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
        {:ok, _} = RaftEx.Log.open(node_id)

        indices =
          for i <- 1..n do
            {:ok, idx} = RaftEx.Log.append(node_id, term, {:set, "k#{i}", i})
            idx
          end

        assert indices == Enum.to_list(1..n)
        assert RaftEx.Log.last_index(node_id) == n

        RaftEx.Log.close(node_id)
        File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      end
    end

    property "truncate_from leaves indices 1..(from-1) intact" do
      check all(
              total <- StreamData.integer(3..15),
              from <- StreamData.integer(2..total)
            ) do
        node_id = :"prop_trunc_#{:erlang.unique_integer([:positive])}"
        tmp = System.tmp_dir!()
        File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
        {:ok, _} = RaftEx.Log.open(node_id)

        for i <- 1..total, do: RaftEx.Log.append(node_id, 1, {:set, "k#{i}", i})

        RaftEx.Log.truncate_from(node_id, from)

        for i <- 1..(from - 1), do: assert(RaftEx.Log.get(node_id, i) != nil)
        for i <- from..total, do: assert(RaftEx.Log.get(node_id, i) == nil)
        assert RaftEx.Log.last_index(node_id) == from - 1

        RaftEx.Log.close(node_id)
        File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      end
    end

    property "append_entries is idempotent — same entries twice = same log" do
      check all(
              n <- StreamData.integer(1..10),
              term <- StreamData.integer(1..5)
            ) do
        node_id = :"prop_idem_#{:erlang.unique_integer([:positive])}"
        tmp = System.tmp_dir!()
        File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
        {:ok, _} = RaftEx.Log.open(node_id)

        entries = for i <- 1..n, do: {i, term, {:set, "k#{i}", i}}

        :ok = RaftEx.Log.append_entries(node_id, 0, entries)
        first_last = RaftEx.Log.last_index(node_id)

        :ok = RaftEx.Log.append_entries(node_id, 0, entries)
        second_last = RaftEx.Log.last_index(node_id)

        assert first_last == second_last
        assert first_last == n

        RaftEx.Log.close(node_id)
        File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      end
    end
  end
end
