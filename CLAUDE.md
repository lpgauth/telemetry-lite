# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
rebar3 compile          # compile
rebar3 ct               # run all tests
rebar3 ct --suite telemetry_SUITE          # run functional tests only
rebar3 ct --suite telemetry_bench_SUITE    # run benchmarks
rebar3 ct --case invoke_handler            # run a single test case
rebar3 fmt              # format all source files
rebar3 fmt --check      # check formatting without writing
rebar3 xref             # cross-reference checks
rebar3 dialyzer         # type analysis
```

## Architecture

This is a drop-in replacement for the `telemetry` library (same module name, same API). The core design splits reads and writes across two storage layers:

- **Write path**: `telemetry_handler_table` (gen_server) owns all mutable state. `attach`/`detach` calls go through it via `gen_server:call`. It maintains two maps in state: `handlers` (event_name → [#handler{}]) and `ids` (handler_id → [event_name]).
- **Read path**: `execute/3` in `telemetry.erl` calls `persistent_term:get({telemetry, EventName}, [])` directly — it never contacts the gen_server. Every write also updates `persistent_term` so reads are always lock-free.

The `#handler{}` record (defined in `telemetry.hrl`) is the internal representation. Handlers are stored in `persistent_term` as `[{Function, Config}]` tuples (via `to_fc/1`) to keep the hot path minimal.

`terminate/2` in `telemetry_handler_table` erases all `persistent_term` entries on shutdown. The gen_server sets `trap_exit` to ensure this cleanup runs.

## Key tradeoffs vs full telemetry

- `persistent_term:put/erase` triggers a system-wide GC — `attach`/`detach` are expensive and should only happen at startup/shutdown, not at runtime under load.
- Handler crashes propagate to the `execute/3` caller (full telemetry catches and detaches).
- `list_handlers/1` does prefix matching; full telemetry does exact matching.
