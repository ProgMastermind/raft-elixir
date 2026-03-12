# AGENTS.md

## Cursor Cloud specific instructions

### Runtime

Erlang/OTP 27 and Elixir 1.18 are managed via [mise](https://mise.jdx.dev/). The update script activates mise automatically; if you open a new shell, run `eval "$(/home/ubuntu/.local/bin/mise activate bash)"` first.

### Key commands

All standard commands are documented in the README. Quick reference:

| Action | Command |
|---|---|
| Install deps | `mix deps.get` |
| Compile | `mix compile` |
| Lint | `mix credo --strict` |
| Type check | `mix dialyzer` |
| Run tests | `mix test` |
| Run demo | `mix run scripts/demo.exs` |
| CI alias | `mix ci` (compile --warnings-as-errors + credo --strict + test) |

### Caveats

- **Flaky consensus tests**: Some tests in `test/raft_ex/joint_consensus_test.exs` and `test/raft_ex/fault_tolerance_test.exs` are timing-sensitive. If a test fails on the first run, re-run it once before investigating — Raft election timeouts can cause non-deterministic log ordering.
- **DETS cleanup**: Tests and the demo script create DETS files in `/tmp` (e.g. `raft_ex_*_meta.dets`, `raft_ex_*_log.dets`). The demo script cleans up its own files, but leftover DETS files from crashed test runs can occasionally cause issues. If you see unexpected persistence state, delete `/tmp/raft_ex_*` files.
- **No external services**: This project has zero external dependencies (no databases, Docker, or network services). Everything runs inside the BEAM VM using DETS for persistence and TCP on localhost for inter-node communication.
