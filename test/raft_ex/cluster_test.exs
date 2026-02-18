defmodule RaftEx.ClusterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # ---------------------------------------------------------------------------
  # §5.2 — Majority and quorum
  # ---------------------------------------------------------------------------

  describe "majority (§5.2)" do
    test "majority of 1 is 1" do
      assert RaftEx.Cluster.majority(1) == 1
    end

    test "majority of 3 is 2" do
      assert RaftEx.Cluster.majority(3) == 2
    end

    test "majority of 5 is 3" do
      assert RaftEx.Cluster.majority(5) == 3
    end

    test "majority of 7 is 4" do
      assert RaftEx.Cluster.majority(7) == 4
    end
  end

  describe "has_majority? (§5.2)" do
    test "1 vote in cluster of 1 is majority" do
      assert RaftEx.Cluster.has_majority?(1, 1) == true
    end

    test "2 votes in cluster of 3 is majority" do
      assert RaftEx.Cluster.has_majority?(2, 3) == true
    end

    test "1 vote in cluster of 3 is NOT majority" do
      assert RaftEx.Cluster.has_majority?(1, 3) == false
    end

    test "3 votes in cluster of 5 is majority" do
      assert RaftEx.Cluster.has_majority?(3, 5) == true
    end

    test "2 votes in cluster of 5 is NOT majority" do
      assert RaftEx.Cluster.has_majority?(2, 5) == false
    end
  end

  describe "peers (§5.2)" do
    test "peers excludes self from cluster list" do
      cluster = [:n1, :n2, :n3]
      assert RaftEx.Cluster.peers(cluster, :n1) == [:n2, :n3]
      assert RaftEx.Cluster.peers(cluster, :n2) == [:n1, :n3]
      assert RaftEx.Cluster.peers(cluster, :n3) == [:n1, :n2]
    end

    test "peers of single-node cluster is empty" do
      assert RaftEx.Cluster.peers([:n1], :n1) == []
    end

    test "size returns cluster length" do
      assert RaftEx.Cluster.size([:n1, :n2, :n3]) == 3
      assert RaftEx.Cluster.size([:n1]) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3, §5.4.2 — quorum_match_index
  # ---------------------------------------------------------------------------

  describe "quorum_match_index (§5.3, §5.4.2)" do
    test "3 nodes: [5, 4, 3] → majority index is 4" do
      # sorted desc: [5, 4, 3], majority=2, index 1 (0-based) = 4
      assert RaftEx.Cluster.quorum_match_index([5, 4, 3]) == 4
    end

    test "3 nodes: [5, 5, 1] → majority index is 5" do
      assert RaftEx.Cluster.quorum_match_index([5, 5, 1]) == 5
    end

    test "3 nodes: [10, 10, 10] → majority index is 10" do
      assert RaftEx.Cluster.quorum_match_index([10, 10, 10]) == 10
    end

    test "5 nodes: [10, 8, 6, 4, 2] → majority index is 6" do
      # sorted desc: [10, 8, 6, 4, 2], majority=3, index 2 (0-based) = 6
      assert RaftEx.Cluster.quorum_match_index([10, 8, 6, 4, 2]) == 6
    end

    test "1 node: [5] → majority index is 5" do
      assert RaftEx.Cluster.quorum_match_index([5]) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # StreamData property test — quorum correctness
  # ---------------------------------------------------------------------------

  describe "property-based quorum invariants (§5.3)" do
    property "quorum_match_index always returns the majority value" do
      check all(vals <- StreamData.list_of(StreamData.integer(0..100), length: 1..7)) do
        sorted = Enum.sort(vals, :desc)
        n = length(sorted)
        maj = div(n, 2) + 1
        expected = Enum.at(sorted, maj - 1)
        assert RaftEx.Cluster.quorum_match_index(vals) == expected
      end
    end
  end
end
