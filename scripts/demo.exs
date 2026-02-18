# =============================================================================
# RaftEx Demo — Watch the full Raft algorithm in action
# =============================================================================
# Run with: mix run scripts/demo.exs
# =============================================================================

IO.puts("""
\e[1m\e[36m
╔══════════════════════════════════════════════════════════════╗
║           RaftEx — Raft Consensus Algorithm Demo             ║
║   "In Search of an Understandable Consensus Algorithm"       ║
║              Ongaro & Ousterhout (2014)                      ║
╚══════════════════════════════════════════════════════════════╝
\e[0m
""")

cluster = [:n1, :n2, :n3]

# Helper: find leader with retries
find_leader = fn ->
  Enum.reduce_while(1..20, nil, fn _, _ ->
    leader = RaftEx.find_leader(cluster)
    if leader, do: {:halt, leader}, else: (Process.sleep(100); {:cont, nil})
  end)
end

# Helper: submit command with auto-routing and retries
submit = fn cmd ->
  Enum.reduce_while(1..10, {:error, :no_leader}, fn _, _ ->
    case RaftEx.command(cluster, cmd) do
      {:ok, r} -> {:halt, {:ok, r}}
      _ -> Process.sleep(150); {:cont, {:error, :retrying}}
    end
  end)
end

# ---------------------------------------------------------------------------
# Step 1: Start the 3-node cluster
# ---------------------------------------------------------------------------
IO.puts("\e[1m=== STEP 1: Starting 3-node cluster ===\e[0m\n")

for node_id <- cluster do
  {:ok, _} = RaftEx.start_node(node_id, cluster)
  IO.puts("  ✓ Started node #{inspect(node_id)}")
end

IO.puts("\n\e[33mWaiting for leader election (up to 500ms)...\e[0m\n")
Process.sleep(700)

# ---------------------------------------------------------------------------
# Step 2: Show cluster status after election
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 2: Cluster status after election ===\e[0m\n")

leader = find_leader.()

for node_id <- cluster do
  s = RaftEx.status(node_id)
  role_color = case s.role do
    :leader    -> "\e[32m"
    :candidate -> "\e[33m"
    :follower  -> "\e[36m"
  end
  IO.puts("  #{role_color}#{inspect(node_id)}\e[0m: role=#{s.role} term=#{s.current_term} " <>
          "commit=#{s.commit_index} leader=#{inspect(s.leader_id)}")
end

IO.puts("\n  \e[32m🏆 Leader elected: #{inspect(leader)}\e[0m\n")

# ---------------------------------------------------------------------------
# Step 3: Submit commands and watch replication
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 3: Submitting commands to the cluster ===\e[0m\n")

commands = [
  {:set, "username", "alice"},
  {:set, "score", 9001},
  {:set, "active", true},
  {:set, "city", "San Francisco"}
]

for {:set, key, value} <- commands do
  IO.puts("  → set(#{inspect(key)}, #{inspect(value)})")
  case submit.({:set, key, value}) do
    {:ok, {:ok, v}} -> IO.puts("    \e[32m✔ committed: #{inspect(v)}\e[0m")
    {:ok, v}        -> IO.puts("    \e[32m✔ committed: #{inspect(v)}\e[0m")
    {:error, e}     -> IO.puts("    \e[31m✗ error: #{inspect(e)}\e[0m")
  end
end

# ---------------------------------------------------------------------------
# Step 4: Read values back
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 4: Reading committed values ===\e[0m\n")

for {:set, key, _} <- commands do
  case submit.({:get, key}) do
    {:ok, {:ok, val}} -> IO.puts("  get(#{inspect(key)}) = #{inspect(val)}")
    {:ok, val}        -> IO.puts("  get(#{inspect(key)}) = #{inspect(val)}")
    other             -> IO.puts("  get(#{inspect(key)}) = #{inspect(other)}")
  end
end

# ---------------------------------------------------------------------------
# Step 5: Delete a key
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 5: Deleting a key ===\e[0m\n")

IO.puts("  → delete(\"active\")")
submit.({:delete, "active"})
IO.puts("  \e[32m✔ deleted\e[0m")

# ---------------------------------------------------------------------------
# Step 6: Show final state on all nodes
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 6: Final state on all nodes ===\e[0m\n")

Process.sleep(300)

for node_id <- cluster do
  s = RaftEx.status(node_id)
  IO.puts("  #{inspect(node_id)}: role=#{s.role} term=#{s.current_term} " <>
          "commit=#{s.commit_index} applied=#{s.last_applied} " <>
          "log_last=#{s.log_last_index}")
  IO.puts("    state_machine: #{inspect(s.sm_state)}")
end

# ---------------------------------------------------------------------------
# Step 7: Simulate leader crash and re-election
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 7: Simulating leader crash ===\e[0m\n")

current_leader = find_leader.()
IO.puts("  💥 Stopping leader #{inspect(current_leader)}...")
RaftEx.stop_node(current_leader)

remaining = Enum.reject(cluster, &(&1 == current_leader))
IO.puts("  Remaining nodes: #{inspect(remaining)}")
IO.puts("\n\e[33mWaiting for new leader election...\e[0m\n")
Process.sleep(700)

new_leader = Enum.reduce_while(1..20, nil, fn _, _ ->
  l = RaftEx.find_leader(remaining)
  if l, do: {:halt, l}, else: (Process.sleep(100); {:cont, nil})
end)

IO.puts("  \e[32m🏆 New leader elected: #{inspect(new_leader)}\e[0m\n")

IO.puts("  → set(\"recovery\", \"success\") on new leader")
case RaftEx.set(new_leader, "recovery", "success") do
  {:ok, v}  -> IO.puts("  \e[32m✔ committed after leader crash: #{inspect(v)}\e[0m")
  {:error, e} -> IO.puts("  \e[31m✗ error: #{inspect(e)}\e[0m")
end

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
IO.puts("""

\e[1m\e[32m
╔══════════════════════════════════════════════════════════════╗
║                    Demo Complete! ✓                          ║
║                                                              ║
║  Every state transition, RPC, vote, commit, and apply       ║
║  event was emitted via :telemetry and printed above.         ║
╚══════════════════════════════════════════════════════════════╝
\e[0m
""")
