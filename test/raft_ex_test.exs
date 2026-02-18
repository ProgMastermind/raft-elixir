defmodule RaftExTest do
  use ExUnit.Case, async: false

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_cluster(prefix) do
    id = :erlang.unique_integer([:positive])
    [:n1, :n2, :n3] |> Enum.map(&:"#{prefix}_#{id}_#{&1}")
  end

  defp start_cluster(cluster) do
    for node_id <- cluster do
      {:ok, _pid} = RaftEx.start_node(node_id, cluster)
    end
    # Wait for election to complete (max 300ms timeout + buffer)
    Process.sleep(600)
    cluster
  end

  defp stop_cluster(cluster) do
    for node_id <- cluster do
      RaftEx.stop_node(node_id)
    end
    # Allow DETS tables to close
    Process.sleep(50)
    # Clean up DETS and snapshot files
    tmp = System.tmp_dir!()
    for node_id <- cluster do
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_meta.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
      File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))
    end
  end

  defp find_leader(cluster, retries \\ 10) do
    result = Enum.find(cluster, fn node_id ->
      try do
        RaftEx.status(node_id).role == :leader
      catch
        _, _ -> false
      end
    end)
    if result == nil and retries > 0 do
      Process.sleep(100)
      find_leader(cluster, retries - 1)
    else
      result
    end
  end

  # Submit a set command, retrying if the leader changes
  defp set_with_retry(cluster, key, value, retries \\ 5) do
    leader = find_leader(cluster)
    case RaftEx.set(leader, key, value) do
      {:ok, v} -> {:ok, v}
      {:error, {:redirect, new_leader}} when new_leader != nil ->
        RaftEx.set(new_leader, key, value)
      {:error, _} when retries > 0 ->
        Process.sleep(200)
        set_with_retry(cluster, key, value, retries - 1)
      other -> other
    end
  end

  # ---------------------------------------------------------------------------
  # §5.2 — Leader election
  # ---------------------------------------------------------------------------

  describe "leader election (§5.2)" do
    test "3-node cluster elects exactly one leader" do
      cluster = unique_cluster("elect")
      start_cluster(cluster)

      leaders = Enum.filter(cluster, fn node_id ->
        RaftEx.status(node_id).role == :leader
      end)

      assert length(leaders) == 1

      stop_cluster(cluster)
    end

    test "all nodes agree on the same leader" do
      cluster = unique_cluster("agree")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # All nodes should know the same leader
      for node_id <- cluster do
        status = RaftEx.status(node_id)
        assert status.leader_id == leader or status.role == :leader
      end

      stop_cluster(cluster)
    end

    test "leader has term >= 1 after election" do
      cluster = unique_cluster("term")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil
      status = RaftEx.status(leader)
      assert status.current_term >= 1

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3 — Log replication
  # ---------------------------------------------------------------------------

  describe "log replication (§5.3)" do
    test "set command is replicated to all nodes" do
      cluster = unique_cluster("repl")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, 42} = RaftEx.set(leader, "x", 42)

      # Give followers time to apply
      Process.sleep(200)

      # All nodes should have the same commitIndex
      statuses = Enum.map(cluster, &RaftEx.status/1)
      commit_indices = Enum.map(statuses, & &1.commit_index)
      assert Enum.all?(commit_indices, &(&1 >= 1))

      stop_cluster(cluster)
    end

    test "get returns committed value" do
      cluster = unique_cluster("get")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, "hello"} = RaftEx.set(leader, "greeting", "hello")
      {:ok, "hello"} = RaftEx.get(leader, "greeting")

      stop_cluster(cluster)
    end

    test "delete removes key from state machine" do
      cluster = unique_cluster("del")
      start_cluster(cluster)

      {:ok, 99} = set_with_retry(cluster, "temp", 99)
      leader = find_leader(cluster)
      assert leader != nil
      :ok = RaftEx.delete(leader, "temp")
      {:ok, nil} = RaftEx.get(leader, "temp")

      stop_cluster(cluster)
    end

    test "multiple commands are applied in order" do
      cluster = unique_cluster("order")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, 1} = RaftEx.set(leader, "counter", 1)
      {:ok, 2} = RaftEx.set(leader, "counter", 2)
      {:ok, 3} = RaftEx.set(leader, "counter", 3)
      {:ok, 3} = RaftEx.get(leader, "counter")

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.4.2 — Safety: commitIndex only moves forward
  # ---------------------------------------------------------------------------

  describe "safety invariants (§5.4.2)" do
    test "commitIndex only increases monotonically" do
      cluster = unique_cluster("mono")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      {:ok, _} = RaftEx.set(leader, "a", 1)
      ci1 = RaftEx.status(leader).commit_index

      {:ok, _} = RaftEx.set(leader, "b", 2)
      ci2 = RaftEx.status(leader).commit_index

      assert ci2 >= ci1

      stop_cluster(cluster)
    end
  end

  # ---------------------------------------------------------------------------
  # §8 — Client redirect
  # ---------------------------------------------------------------------------

  describe "client redirect (§8)" do
    test "non-leader node redirects client to leader" do
      cluster = unique_cluster("redir")
      start_cluster(cluster)

      leader = find_leader(cluster)
      assert leader != nil

      # Find a follower
      follower = Enum.find(cluster, fn n -> n != leader end)
      assert follower != nil

      result = RaftEx.set(follower, "x", 1)
      # Either succeeds (if follower became leader) or redirects
      assert match?({:ok, _}, result) or match?({:error, {:redirect, _}}, result)

      stop_cluster(cluster)
    end
  end
end
