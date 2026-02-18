# =============================================================================
# RaftEx Demo — Watch the full Raft algorithm in action
# =============================================================================
# Run with: mix run scripts/demo.exs
#
# This demo starts a 3-node Raft cluster and shows every state transition,
# RPC, vote, commit, and apply event in real time via telemetry + Inspector.
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

# ---------------------------------------------------------------------------
# Step 1: Start the 3-node cluster
# ---------------------------------------------------------------------------
IO.puts("\e[1m=== STEP 1: Starting 3-node cluster ===\e[0m\n")

for node_id <- cluster do
  {:ok, _} = RaftEx.start_node(node_id, cluster)
  IO.puts("  ✓ Started node #{inspect(node_id)}")
end

IO.puts("\n\e[33mWaiting for leader election (up to 300ms)...\e[0m\n")
Process.sleep(700)

# ---------------------------------------------------------------------------
# Step 2: Show cluster status after election
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 2: Cluster status after election ===\e[0m\n")

leader = RaftEx.find_leader(cluster)

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
  {"username", "alice"},
  {"score", 9001},
  {"active", true},
  {"city", "San Francisco"}
]

for {key, value} <- commands do
  IO.puts("  → set(#{inspect(key)}, #{inspect(value)})")
  case RaftEx.set(leader, key, value) do
    {:ok, v}  -> IO.puts("    \e[32m✔ committed: #{inspect(v)}\e[0m")
    {:error, e} -> IO.puts("    \e[31m✗ error: #{inspect(e)}\e[0m")
  end
end

# ---------------------------------------------------------------------------
# Step 4: Read values back
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 4: Reading committed values ===\e[0m\n")

for {key, _} <- commands do
  {:ok, val} = RaftEx.get(leader, key)
  IO.puts("  get(#{inspect(key)}) = #{inspect(val)}")
end

# ---------------------------------------------------------------------------
# Step 5: Delete a key
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 5: Deleting a key ===\e[0m\n")

IO.puts("  → delete(\"active\")")
:ok = RaftEx.delete(leader, "active")
{:ok, nil} = RaftEx.get(leader, "active")
IO.puts("  \e[32m✔ deleted — get(\"active\") = nil\e[0m")

# ---------------------------------------------------------------------------
# Step 6: Show final state on all nodes
# ---------------------------------------------------------------------------
IO.puts("\n\e[1m=== STEP 6: Final state on all nodes ===\e[0m\n")

Process.sleep(200)

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

IO.puts("  💥 Stopping leader #{inspect(leader)}...")
RaftEx.stop_node(leader)

remaining = Enum.reject(cluster, &(&1 == leader))
IO.puts("  Remaining nodes: #{inspect(remaining)}")
IO.puts("\n\e[33mWaiting for new leader election...\e[0m\n")
Process.sleep(700)

new_leader = RaftEx.find_leader(remaining)
IO.puts("  \e[32m🏆 New leader elected: #{inspect(new_leader)}\e[0m\n")

# Submit a command to the new leader
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
