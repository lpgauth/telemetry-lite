-module(telemetry_bench_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(ITERATIONS, 1000000).
-define(EVENT, [http, request, done]).

all() ->
    [
        execute_no_handlers,
        execute_one_handler,
        execute_three_handlers,
        execute_missing_event
    ].

init_per_suite(Config) ->
    application:ensure_all_started(telemetry),
    Config.

end_per_suite(_Config) ->
    application:stop(telemetry).

init_per_testcase(execute_one_handler, Config) ->
    telemetry:attach(bench_1, ?EVENT, fun ?MODULE:noop_handler/4, []),
    Config;
init_per_testcase(execute_three_handlers, Config) ->
    telemetry:attach(bench_1, ?EVENT, fun ?MODULE:noop_handler/4, []),
    telemetry:attach(bench_2, ?EVENT, fun ?MODULE:noop_handler/4, []),
    telemetry:attach(bench_3, ?EVENT, fun ?MODULE:noop_handler/4, []),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(execute_no_handlers, _Config) ->
    ok;
end_per_testcase(execute_missing_event, _Config) ->
    ok;
end_per_testcase(execute_one_handler, _Config) ->
    telemetry:detach(bench_1),
    ok;
end_per_testcase(execute_three_handlers, _Config) ->
    telemetry:detach(bench_1),
    telemetry:detach(bench_2),
    telemetry:detach(bench_3),
    ok.

%% 0 handlers attached to the event
execute_no_handlers(_Config) ->
    telemetry:attach(bench_other, [other, event], fun ?MODULE:noop_handler/4, []),
    Ns = bench(fun() -> telemetry:execute(?EVENT, #{}, #{}) end),
    telemetry:detach(bench_other),
    ct:pal("execute/3 0 handlers: ~.1f ns/op (~B iterations)", [Ns, ?ITERATIONS]).

%% 1 handler attached
execute_one_handler(_Config) ->
    Ns = bench(fun() -> telemetry:execute(?EVENT, #{latency => 42}, #{path => <<"/">>}) end),
    ct:pal("execute/3 1 handler:  ~.1f ns/op (~B iterations)", [Ns, ?ITERATIONS]).

%% 3 handlers attached
execute_three_handlers(_Config) ->
    Ns = bench(fun() -> telemetry:execute(?EVENT, #{latency => 42}, #{path => <<"/">>}) end),
    ct:pal("execute/3 3 handlers: ~.1f ns/op (~B iterations)", [Ns, ?ITERATIONS]).

%% event with no handlers ever attached (persistent_term miss)
execute_missing_event(_Config) ->
    Ns = bench(fun() -> telemetry:execute([never, attached], #{}, #{}) end),
    ct:pal("execute/3 miss:       ~.1f ns/op (~B iterations)", [Ns, ?ITERATIONS]).

%% internal

bench(Fun) ->
    %% warmup
    loop(Fun, ?ITERATIONS div 10),
    %% measure
    T0 = erlang:monotonic_time(),
    loop(Fun, ?ITERATIONS),
    T1 = erlang:monotonic_time(),
    erlang:convert_time_unit(T1 - T0, native, nanosecond) / ?ITERATIONS.

loop(_Fun, 0) ->
    ok;
loop(Fun, N) ->
    Fun(),
    loop(Fun, N - 1).

noop_handler(_Event, _Measurements, _Metadata, _Config) ->
    ok.
