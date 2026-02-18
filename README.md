# RaftEx

A complete, spec-faithful implementation of the Raft consensus algorithm in Elixir.

> "In Search of an Understandable Consensus Algorithm"  
> — Ongaro & Ousterhout (2014)

Every rule from the paper is implemented and cited. Every invariant has a test.

---

## What's implemented

| Paper Section | Feature |
|---|---|
| §5.1 | Persistent state — `currentTerm`, `votedFor`, `log[]` written to DETS before any RPC |
| §5.2 | Leader election — randomized timeout (150–300ms), RequestVote, majority vote counting |
| §5.3 | Log replication — AppendEntries with all 5 receiver rules, `nextIndex`/`matchIndex` |
| §5.4.1 | Election restriction — log up-to-date check (term first, then length) |
| §5.4.2 | Commit discipline — leader only advances `commitIndex` for current-term entries |
| §5.5 | Fault tolerance — follower crash, leader crash, automatic re-election and catch-up |
| §5.6 | Timing — 50ms heartbeat `<<` 150–300ms election timeout |
| §6 | Joint consensus — `C_old,new` two-phase membership change, graceful node removal |
| §7 | Log compaction — snapshot create/load, `InstallSnapshot` RPC, log truncation |
| §8 | Client interaction — redirect to leader, no-op on election, linearizable reads |

---

## Project structure

```
raft_ex_v2/
├── lib/raft_ex/
│   ├── server.ex        # :gen_statem FSM — follower/candidate/leader roles
│   ├── log.ex           # DETS-backed log storage
│   ├── persistence.ex   # DETS-backed currentTerm + votedFor
│   ├── rpc.ex           # Message structs (AppendEntries, RequestVote, InstallSnapshot)
│   ├── cluster.ex       # Peer list, majority/joint-majority helpers
│   ├── state_machine.ex # KV store — set/get/delete
│   ├── snapshot.ex      # Snapshot create/load/install
│   ├── inspector.ex     # Telemetry handler — prints every event to stdout
│   └── application.ex   # OTP supervision tree
├── lib/raft_ex.ex        # Public API
├── scripts/demo.exs      # Full interactive demo
└── test/raft_ex/
    ├── persistence_test.exs
    ├── log_test.exs
    ├── rpc_test.exs
    ├── cluster_test.exs
    ├── state_machine_test.exs
    ├── snapshot_test.exs
    ├── server_unit_test.exs
    ├── fault_tolerance_test.exs
    └── joint_consensus_test.exs
```

---

## Quick start

```bash
cd raft_ex_v2
mix deps.get
mix compile
```

Run the full demo (shows every state transition, RPC, vote, commit, and apply):

```bash
mix run scripts/demo.exs
```

Run all tests:

```bash
mix test
```

---

## Using the API

### Start a cluster

```elixir
cluster = [:n1, :n2, :n3]

# Start each node — all nodes need to know the full cluster
{:ok, _} = RaftEx.start_node(:n1, cluster)
{:ok, _} = RaftEx.start_node(:n2, cluster)
{:ok, _} = RaftEx.start_node(:n3, cluster)

# Wait for election (150–300ms)
Process.sleep(500)
```

### Find the leader

```elixir
leader = RaftEx.find_leader(cluster)
# => :n1  (whichever won the election)
```

### Write and read data

```elixir
{:ok, "alice"} = RaftEx.set(leader, "username", "alice")
{:ok, "alice"} = RaftEx.get(leader, "username")
{:ok, :ok}     = RaftEx.delete(leader, "username")
```

### Send a command to any node (auto-redirects to leader)

```elixir
# Works even if you don't know who the leader is
{:ok, result} = RaftEx.command(cluster, {:set, "key", "value"})
```

### Inspect node state

```elixir
RaftEx.status(:n1)
# => %{
#   node_id: :n1,
#   role: :follower,
#   current_term: 3,
#   commit_index: 7,
#   last_applied: 7,
#   leader_id: :n2,
#   log_last_index: 7,
#   sm_state: %{"username" => "alice"}
# }
```

### Stop a node

```elixir
RaftEx.stop_node(:n1)
```

### Cluster membership change (§6)

```elixir
# Add a node — start it first, then submit config_change
{:ok, _} = RaftEx.start_node(:n4, [:n1, :n2, :n3, :n4])
{:ok, _} = RaftEx.Server.command(leader, {:config_change, [:n1, :n2, :n3, :n4]})

# Remove a node — submit config_change, node shuts down after commit
{:ok, _} = RaftEx.Server.command(leader, {:config_change, [:n1, :n2, :n3]})
```

### Create a snapshot (§7)

```elixir
s = RaftEx.status(leader)
{:ok, snap} = RaftEx.Snapshot.create(
  leader,
  s.commit_index,
  s.current_term,
  cluster,
  s.sm_state
)
# snap.last_included_index, snap.last_included_term, snap.data
```

---

## How it works

### Roles

Each node runs as a `:gen_statem` with three named state functions:

- **`follower/3`** — default state; resets election timer on valid heartbeat or vote grant
- **`candidate/3`** — increments term, votes for self, sends `RequestVote` to all peers
- **`leader/3`** — sends heartbeats every 50ms, replicates log entries, advances `commitIndex`

### Persistence

Before responding to any RPC, the server writes to DETS:

```
{:raft_meta, node_id}  →  {:current_term, N}  and  {:voted_for, atom | nil}
{:raft_log, node_id}   →  {index, term, command}  entries
```

On restart, these are loaded back before the FSM starts — `currentTerm` never goes backward.

### Log replication flow

```
Client → leader.command/2
  → Log.append (DETS)
  → AppendEntries to all peers
  → peers reply AppendEntriesReply{success: true, match_index: N}
  → leader advances matchIndex[peer]
  → maybe_advance_commit: if majority have matchIndex >= N and log[N].term == currentTerm
  → apply_committed_entries: StateMachine.apply_entries
  → reply to client
```

### Observability

Every event emits a `:telemetry` event and is printed by `RaftEx.Inspector`:

```
[NODE :n1] [LEADER] 📝 appended index=4 term=2 cmd={:set, "key", "val"}
[NODE :n1] → SEND AppendEntries to n2
[NODE :n2] ← REPLY AppendEntriesReply to n1
[NODE :n1] ✔ COMMITTED up to index=4
[NODE :n1] ⚙ APPLIED index=4 result={:ok, "val"}
```

---

## Tests

```
4 properties, 124 tests, 0 failures
```

| File | What it tests |
|---|---|
| `persistence_test.exs` | DETS read/write, crash recovery |
| `log_test.exs` | Append, truncate, conflict detection, property tests |
| `rpc_test.exs` | Struct construction and serialization |
| `cluster_test.exs` | Majority, joint majority, peer list |
| `state_machine_test.exs` | KV set/get/delete, apply_entries |
| `snapshot_test.exs` | Create, load, install |
| `server_unit_test.exs` | FSM logic — election, replication, commit |
| `fault_tolerance_test.exs` | Leader crash, follower crash, network partition |
| `joint_consensus_test.exs` | §6 node removal shutdown, joint majority voting |

---

## Timing constants

| Constant | Value | Paper ref |
|---|---|---|
| Election timeout | 150–300ms (random) | §5.2 |
| Heartbeat interval | 50ms | §5.2 |
| RPC call timeout | 5000ms | §8 |

---

## Reference

- Paper: https://raft.github.io/raft.pdf  
- Visualization: https://raft.github.io  
- Elixir docs: https://elixir-lang.org/docs.html
