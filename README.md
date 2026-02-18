# RaftEx

A complete, spec-compliant implementation of the **Raft consensus algorithm** in Elixir/OTP.

> "In Search of an Understandable Consensus Algorithm"  
> — Diego Ongaro & John Ousterhout (2014)

---

## What is Raft?

Raft is a consensus algorithm designed to be understandable. It solves the problem of getting a
cluster of servers to agree on a sequence of values (a replicated log), even in the presence of
failures. Raft decomposes consensus into three relatively independent sub-problems:

1. **Leader election** — one server is elected leader; it handles all client requests
2. **Log replication** — the leader accepts log entries and replicates them to followers
3. **Safety** — if any server has applied a log entry at a given index, no other server will
   ever apply a different command for that index

---

## Architecture

```
RaftEx.Application
├── RaftEx.Inspector          # Telemetry observer (observability)
└── RaftEx.NodeSupervisor     # DynamicSupervisor for Raft nodes
    ├── RaftEx.Server (:n1)   # :gen_statem FSM (follower/candidate/leader)
    ├── RaftEx.Server (:n2)
    └── RaftEx.Server (:n3)
```

### Modules

| Module | Responsibility | Paper Section |
|--------|---------------|---------------|
| `RaftEx.Persistence` | currentTerm + votedFor (DETS) | §5.1 |
| `RaftEx.Log` | Log storage, conflict-aware append, truncation (DETS) | §5.3 |
| `RaftEx.RPC` | Message structs: RequestVote, AppendEntries, InstallSnapshot | §5.2, §5.3, §7 |
| `RaftEx.Cluster` | Peer list, quorum math | §5.2, §5.3 |
| `RaftEx.StateMachine` | KV store, apply commands | §5.3 |
| `RaftEx.Snapshot` | Snapshot create/save/load/install, log compaction | §7 |
| `RaftEx.Inspector` | Telemetry handler, colored stdout output | — |
| `RaftEx.Server` | :gen_statem FSM — follower, candidate, leader | §5.1–§5.6, §7, §8 |
| `RaftEx` | Public API: start_node, set, get, delete | §8 |

---

## Build Phases

This project was built incrementally, phase by phase:

| Phase | What was added | Tag |
|-------|---------------|-----|
| 1 | Project scaffold, OTP application, supervision tree | `phase-1-scaffold` |
| 2 | Persistent state layer — currentTerm, votedFor (§5.1) | `phase-2-persistence` |
| 3 | Log storage layer — DETS-backed, conflict-aware (§5.3) | `phase-3-log` |
| 4 | RPC message structs — all 6 types (§5.2, §5.3, §7) | `phase-4-rpc` |
| 5 | Cluster & quorum math (§5.2, §5.3) | `phase-5-cluster` |
| 6 | State machine + snapshot storage (§5.3, §7) | `phase-6-statemachine` |
| 7 | Inspector & telemetry observability | `phase-7-inspector` |
| 8 | FSM: follower + candidate — leader election (§5.1, §5.2, §5.4.1) | `phase-8-election` |
| 9 | FSM: leader — log replication + commit + snapshots (§5.3, §5.4.2, §7, §8) | `phase-9-replication` |
| 10 | Public API + demo script + full integration tests (§8) | `phase-10-complete` |

---

## Quick Start

```bash
# Install dependencies
cd raft_ex_v2
mix deps.get

# Run tests
mix test

# Run the demo (shows full data flow)
mix run scripts/demo.exs
```

---

## Demo Output

The demo starts a 3-node cluster and shows every state transition, RPC, and commit:

```
[NODE :n1] [FOLLOWER] term=0 | init → follower
[NODE :n2] [FOLLOWER] term=0 | init → follower
[NODE :n3] [FOLLOWER] term=0 | init → follower
[NODE :n2] [FOLLOWER] ⏰ election timeout fired, starting election for term 1
[NODE :n2] [CANDIDATE] term=1 | follower → candidate
[NODE :n2] [CANDIDATE] → SEND RequestVote to :n1
[NODE :n2] [CANDIDATE] → SEND RequestVote to :n3
[NODE :n1] [FOLLOWER] ← RECV RequestVote from :n2
[NODE :n1] [FOLLOWER] ← REPLY RequestVoteReply to :n2
[NODE :n2] [LEADER] 🏆 WON election! term=1, votes=2
[NODE :n2] [LEADER] term=1 | candidate → leader
...
```

---

## Spec Compliance

Every rule from Figure 2 of the Raft paper is implemented:

- ✅ Persistent state written to DETS before any RPC response (§5.1)
- ✅ Randomized election timeout 150–300ms (§5.2)
- ✅ Majority vote with split-vote restart (§5.2)
- ✅ Conflict-aware log truncation (§5.3)
- ✅ Idempotent AppendEntries (§5.3)
- ✅ commitIndex monotonically increasing (§5.3)
- ✅ Election restriction: up-to-date log check (§5.4.1)
- ✅ Leader only commits current-term entries + no-op on election (§5.4.2)
- ✅ Heartbeat 50ms, election 150–300ms (§5.6)
- ✅ Snapshot create/save/load/install, log compaction (§7)
- ✅ Client redirect to leader, linearizable reads (§8)

---

## Testing

```bash
mix test
# 4 properties, 40 tests, 0 failures
```

Tests cover:
- Unit tests for every module in isolation
- Integration tests for 3-node cluster (election, replication, fault tolerance)
- StreamData property tests for log invariants
- Snapshot install on lagging follower
