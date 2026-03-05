# RaftEx

A from-scratch implementation of the [Raft consensus algorithm](https://raft.github.io/raft.pdf) in Elixir, built on OTP's `gen_statem`.

Covers leader election, log replication, persistence, snapshots, joint consensus membership changes, and a TCP transport layer — about 1200 lines total. Each function in the codebase is annotated with the paper section it implements.

I wrote a detailed blog post about the design decisions and implementation: [I Built Raft Consensus From Scratch in Elixir. Here's What the Paper Doesn't Tell You.](https://hashnode.com/edit/cmmdvamtp00q01qj01fz7fgw8)

---

## What's Implemented

| Paper Section | What it covers |
|---|---|
| §5.1 | `currentTerm`, `votedFor`, and log persisted to DETS before any RPC response |
| §5.2 | Leader election with randomized timeouts (150–300ms), RequestVote RPC |
| §5.3 | Log replication via AppendEntries, conflict detection, `nextIndex`/`matchIndex` tracking |
| §5.4 | Election restriction (log up-to-date check) and commit safety (current-term-only rule) |
| §5.6 | Heartbeat interval (50ms) ≪ election timeout, ensuring leader stability |
| §6 | Two-phase membership changes via joint consensus (`C_old,new` → `C_new`) |
| §7 | Snapshot creation, log compaction, chunked InstallSnapshot RPC |
| §8 | Client redirect to leader, no-op on election win, linearizable reads |
| Pre-vote | Pre-vote protocol to prevent term inflation from partitioned nodes |
| Fast backtrack | Conflict-aware log backtracking to reduce catch-up round trips |

---

## Quick Start

```bash
git clone https://github.com/ProgMastermind/raft-elixir.git
cd raft-elixir
mix deps.get
mix compile
```

**Run the interactive demo** (shows elections, replication, commits, failover, and membership changes):

```bash
mix run scripts/demo.exs
```

**Run all tests:**

```bash
mix test
```

---

## API

### Start a cluster

```elixir
cluster = [:n1, :n2, :n3]

{:ok, _} = RaftEx.start_node(:n1, cluster)
{:ok, _} = RaftEx.start_node(:n2, cluster)
{:ok, _} = RaftEx.start_node(:n3, cluster)

# Wait for election (~300ms)
Process.sleep(500)
```

### Write and read

```elixir
leader = RaftEx.find_leader(cluster)

{:ok, "alice"} = RaftEx.set(leader, "username", "alice")
{:ok, "alice"} = RaftEx.get(leader, "username")
:ok            = RaftEx.delete(leader, "username")
```

Commands sent to a follower are automatically redirected to the leader:

```elixir
{:ok, result} = RaftEx.command(cluster, {:set, "key", "value"})
```

### Inspect node state

```elixir
RaftEx.status(:n1)
# %{
#   role: :follower,
#   current_term: 3,
#   commit_index: 7,
#   last_applied: 7,
#   leader_id: :n2,
#   log_last_index: 7,
#   sm_state: %{"username" => "alice"}
# }
```

### Membership changes (§6)

```elixir
# Add a node
{:ok, _} = RaftEx.start_node(:n4, [:n1, :n2, :n3, :n4])
{:ok, _} = RaftEx.add_node(:n1, :n4, [:n1, :n2, :n3])

# Remove a node (node shuts down after the config change commits)
{:ok, _} = RaftEx.remove_node(:n1, :n4, [:n1, :n2, :n3, :n4])
```

### Stop a node

```elixir
RaftEx.stop_node(:n1)
```

---

## Architecture

```
RaftEx.Supervisor (one_for_one)
├── TcpConnectionPool     — pooled outbound TCP connections, one per peer
├── Inspector             — telemetry handler, logs all Raft events to stdout
└── NodeSupervisor        — DynamicSupervisor
    └── Server (per node) — gen_statem FSM (follower/candidate/leader)
        └── TcpListener   — per-node inbound TCP acceptor
```

### Modules

| Module | Purpose |
|---|---|
| `Server` | Core Raft FSM — election, replication, commit, state transitions |
| `Log` | DETS-backed log with conflict-aware append and truncation |
| `Persistence` | DETS-backed `currentTerm` and `votedFor` with sync-on-write |
| `Cluster` | Quorum math, peer lists, joint majority checks |
| `Snapshot` | Snapshot creation, log compaction, InstallSnapshot handling |
| `StateMachine` | Replicated key-value store (set/get/delete) |
| `RPC` | Message structs and dispatch (RequestVote, AppendEntries, InstallSnapshot, PreVote) |
| `TcpTransport` | 4-byte length-prefixed binary framing over TCP |
| `TcpConnectionPool` | Connection pooling with reconnect-on-failure |
| `TcpListener` | Inbound TCP message loop, deserialize and dispatch to gen_statem |
| `Transport` | Node ID → `{host, port}` endpoint resolution |
| `Inspector` | Telemetry event handler — prints state transitions, RPCs, commits |

### How replication works

```
Client → RaftEx.set(leader, key, value)
       → Server.command/2
       → Log.append to DETS
       → AppendEntries RPC to all peers
       → Followers append, reply with match_index
       → Leader checks: majority replicated AND entry is from current term?
         → Yes: advance commit_index, apply to StateMachine, reply to client
```

### Observability

Every state transition, RPC, vote, and commit emits a `:telemetry` event. `Inspector` prints them:

```
[NODE :n1] [LEADER] appended index=4 term=2 cmd={:set, "key", "val"}
[NODE :n1] → SEND AppendEntries to n2
[NODE :n2] ← REPLY AppendEntriesReply to n1
[NODE :n1] COMMITTED up to index=4
[NODE :n1] APPLIED index=4 result={:ok, "val"}
```

---

## Tests

| Test file | Coverage |
|---|---|
| `persistence_test.exs` | DETS read/write, crash recovery, term monotonicity |
| `log_test.exs` | Append, truncate, conflict detection, property-based tests |
| `rpc_test.exs` | Struct construction and serialization round-trips |
| `cluster_test.exs` | Majority math, joint majority, peer list generation |
| `state_machine_test.exs` | KV set/get/delete, batch apply |
| `snapshot_test.exs` | Create, load, install, log truncation after snapshot |
| `server_unit_test.exs` | FSM transitions — election, replication, commit advancement |
| `fault_tolerance_test.exs` | Leader crash recovery, follower crash recovery, re-election |
| `joint_consensus_test.exs` | Node add/remove, joint majority voting, leader self-removal |
| `tcp_transport_test.exs` | TCP framing, connection behavior, reconnection |

```bash
mix test                    # run all tests
mix test test/raft_ex/server_unit_test.exs   # run a specific file
```

---

## Configuration

Timing constants (in `lib/raft_ex/server.ex`):

| Constant | Value | Raft paper reference |
|---|---|---|
| Election timeout | 150–300ms (randomized) | §5.2 |
| Heartbeat interval | 50ms | §5.2 |
| Snapshot threshold | 100 log entries | §7 |
| Snapshot chunk size | 64 KB | §7 |

TCP endpoints are auto-assigned on `localhost`. To override:

```elixir
RaftEx.start_node(:n1, [:n1, :n2, :n3],
  endpoints: %{
    n1: {"127.0.0.1", 4001},
    n2: {"127.0.0.1", 4002},
    n3: {"127.0.0.1", 4003}
  }
)
```

---

## Requirements

- Elixir >= 1.18
- Erlang/OTP >= 27

---

## References

- [In Search of an Understandable Consensus Algorithm (Ongaro & Ousterhout, 2014)](https://raft.github.io/raft.pdf)
- [Raft Visualization](https://raft.github.io)
