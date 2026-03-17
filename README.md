# telemetry-lite

Lightweight telemetry event dispatching for Erlang and Elixir. A minimal, performance-focused reimplementation of [telemetry](https://github.com/beam-telemetry/telemetry) that optimizes `execute/3` throughput using `persistent_term` for zero-copy handler lookups on the hot path.

## Design

Handlers are stored in a `gen_server` for safe concurrent writes and indexed into `persistent_term` for lock-free reads. `execute/3` never touches the `gen_server` — it reads directly from `persistent_term`, making the common case as fast as a map lookup.

## vs telemetry

`telemetry-lite` is a drop-in replacement for [telemetry](https://github.com/beam-telemetry/telemetry) (same module name, same function signatures) with one architectural difference: it uses `persistent_term` instead of ETS for the read path.

### When to prefer telemetry-lite

`persistent_term` reads are truly lock-free — there is no reader/writer synchronization at all. Under high `execute/3` call rates with many schedulers, this eliminates ETS read contention and produces lower, more consistent latency. The gains are most visible when handlers are stable (registered at startup, rarely changed) and `execute/3` is on a critical path.

### When to prefer telemetry

**`attach`/`detach` trigger a system-wide GC.** Every `persistent_term:put/2` and `persistent_term:erase/1` call schedules a global GC pass across all processes. In telemetry-lite every `attach`, `attach_many`, and `detach` writes at least one `persistent_term` entry. If handlers are registered and deregistered at runtime under load — e.g. per-request or per-connection — this will cause latency spikes across the entire node. Full telemetry uses ETS, which has no such penalty.

**Handler crashes propagate to the caller.** Full telemetry catches exceptions thrown by handlers, detaches the offending handler, and logs a warning — isolating the instrumentation fault from the instrumented code. `telemetry-lite` lets handler crashes propagate directly to the `execute/3` caller. This is simpler and faster but means a buggy handler can crash unrelated processes.

**`list_handlers/1` semantics differ.** Full telemetry's `list_handlers/1` takes an exact event name and returns only handlers attached to that event. `telemetry-lite`'s `list_handlers/1` takes a prefix and returns all handlers whose event name starts with that prefix, making it a superset of the original API.

### Summary

| | telemetry-lite | telemetry |
|---|---|---|
| `execute/3` read | `persistent_term` (lock-free) | ETS (read-locked) |
| `attach`/`detach` write | `persistent_term` + GC pause | ETS (no GC impact) |
| Handler crash | propagates to caller | caught, handler detached |
| `list_handlers/1` | prefix match | exact match |
| Dependencies | none | none |

## API

```erlang
%% Attach a handler to an event
telemetry:attach(HandlerId, EventName, Function, Config) -> ok | {error, already_exists}

%% Attach a handler to multiple events
telemetry:attach_many(HandlerId, EventNames, Function, Config) -> ok | {error, already_exists}

%% Detach a handler
telemetry:detach(HandlerId) -> ok | {error, not_found}

%% Emit an event
telemetry:execute(EventName, Measurements) -> ok
telemetry:execute(EventName, Measurements, Metadata) -> ok

%% Execute a span, emitting start/stop/exception events
telemetry:span(EventPrefix, StartMetadata, SpanFunction) -> term()

%% List handlers matching a prefix
telemetry:list_handlers(EventPrefix) -> [handler()]
```

### Handler function signature

```erlang
fun(EventName, Measurements, Metadata, Config) -> any()
```

### Span function signature

```erlang
fun() -> {Result, StopMetadata}
```

## Usage

### Erlang

```erlang
%% Attach a handler
ok = telemetry:attach(
    my_handler,
    [http, request, done],
    fun(EventName, Measurements, Metadata, Config) ->
        io:format("event=~p measurements=~p~n", [EventName, Measurements])
    end,
    []
),

%% Emit an event
telemetry:execute([http, request, done], #{duration => 42}, #{path => <<"/">>}),

%% Emit a span
Result = telemetry:span([db, query], #{}, fun() ->
    Res = run_query(),
    {Res, #{rows => length(Res)}}
end),

%% Detach
telemetry:detach(my_handler).
```

### Elixir

```elixir
:telemetry.attach(
  :my_handler,
  [:http, :request, :done],
  fn event, measurements, metadata, config ->
    IO.inspect({event, measurements})
  end,
  []
)

:telemetry.execute([:http, :request, :done], %{duration: 42}, %{path: "/"})

:telemetry.detach(:my_handler)
```

## Installation

### rebar3

```erlang
{deps, [{telemetry, "~> 1.0"}]}.
```

### mix

```elixir
{:telemetry, "~> 1.0"}
```

## Benchmarks

Run with `rebar3 ct --suite telemetry_bench_SUITE`:

| Scenario | Throughput |
|---|---|
| 0 handlers attached | 34.2 ns/op |
| 1 handler attached | 35.0 ns/op |
| 3 handlers attached | 44.8 ns/op |
| event never attached (miss) | 25.1 ns/op |
