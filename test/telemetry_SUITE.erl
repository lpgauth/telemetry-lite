-module(telemetry_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("telemetry.hrl").

all() ->
    [
        duplicate_attach,
        invoke_handler,
        list_handlers,
        list_for_prefix,
        no_execute_detached,
        no_execute_on_prefix,
        no_execute_on_specific,
        handler_on_multiple_events,
        list_handler_on_many,
        detach_from_all,
        off_execute,
        crash_propagates,
        span_emits_start_and_stop,
        span_emits_exception_on_throw,
        span_emits_exception_on_error
    ].

init_per_testcase(off_execute, Config) ->
    Config;
init_per_testcase(_, Config) ->
    application:ensure_all_started(telemetry),
    HandlerId = crypto:strong_rand_bytes(16),
    [{id, HandlerId} | Config].

end_per_testcase(off_execute, _Config) ->
    ok;
end_per_testcase(_, Config) ->
    HandlerId = ?config(id, Config),
    telemetry:detach(HandlerId),
    application:stop(telemetry).

%% attaching returns error if handler with the same ID already exists
duplicate_attach(Config) ->
    HandlerId = ?config(id, Config),
    telemetry:attach(HandlerId, [some, event], fun ?MODULE:echo_event/4, []),

    ?assertEqual(
        {error, already_exists},
        telemetry:attach(HandlerId, [some, event], fun ?MODULE:echo_event/4, [])
    ).

%% handler is invoked when event it's attached to is emitted
invoke_handler(Config) ->
    HandlerId = ?config(id, Config),
    Event = [a, test, event],
    HandlerConfig = #{send_to => self()},
    Measurements = #{data => 3},
    Metadata = #{some => metadata},
    telemetry:attach(HandlerId, Event, fun ?MODULE:echo_event/4, HandlerConfig),

    telemetry:execute(Event, Measurements, Metadata),

    receive
        {event, Event, Measurements, Metadata, HandlerConfig} ->
            ok
    after 1000 ->
        ct:fail(timeout_receive_echo)
    end.

%% handlers attached to event can be listed
list_handlers(Config) ->
    HandlerId = ?config(id, Config),
    Event = [a, test, event],
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,
    telemetry:attach(HandlerId, Event, HandlerFun, HandlerConfig),

    ?assertMatch(
        [
            #{
                id := HandlerId,
                event_name := Event,
                function := HandlerFun,
                config := HandlerConfig
            }
        ],
        telemetry:list_handlers(Event)
    ).

%% handlers attached to event prefix can be listed
list_for_prefix(Config) ->
    HandlerId = ?config(id, Config),
    Prefix1 = [],
    Prefix2 = [a],
    Prefix3 = [a, test],
    Event = [a, test, event],
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,
    telemetry:attach(HandlerId, Event, HandlerFun, HandlerConfig),

    [
        ?assertMatch(
            [
                #{
                    id := HandlerId,
                    event_name := Event,
                    function := HandlerFun,
                    config := HandlerConfig
                }
            ],
            telemetry:list_handlers(Prefix)
        )
     || Prefix <- [Prefix1, Prefix2, Prefix3]
    ],

    ?assertEqual([], telemetry:list_handlers(Event ++ [something])).

%% detached handler function is not called when handlers are executed
no_execute_detached(Config) ->
    HandlerId = ?config(id, Config),
    Event = [a, test, event],
    HandlerConfig = #{send_to => self()},
    Measurements = #{data => 3},
    Metadata = #{some => data},
    HandlerFun = fun ?MODULE:echo_event/4,
    telemetry:attach(HandlerId, Event, HandlerFun, HandlerConfig),
    telemetry:detach(HandlerId),
    telemetry:execute(Event, Measurements, Metadata),

    receive
        {event, Event, Measurements, Metadata, HandlerConfig} ->
            ct:fail(detached_executed)
    after 300 ->
        ok
    end.

%% handler is not invoked when prefix of the event it's attached to is emitted
no_execute_on_prefix(Config) ->
    HandlerId = ?config(id, Config),
    Prefix = [a, test],
    Event = [a, test, event],
    Measurements = #{data => 3},
    Metadata = #{some => data},
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,
    telemetry:attach(HandlerId, Event, HandlerFun, HandlerConfig),

    telemetry:execute(Prefix, Measurements, Metadata),

    receive
        {event, Event, Measurements, Metadata, HandlerConfig} ->
            ct:fail(prefix_executed)
    after 300 ->
        ok
    end.

%% handler is not invoked when event more specific than the one it's attached to is emitted
no_execute_on_specific(Config) ->
    HandlerId = ?config(id, Config),
    Event = [a, test],
    MoreSpecificEvent = [a, test, event, specific],
    Measurements = #{data => 3},
    Metadata = #{some => data},
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,
    telemetry:attach(HandlerId, Event, HandlerFun, HandlerConfig),

    telemetry:execute(MoreSpecificEvent, Measurements, Metadata),

    receive
        {event, Event, Measurements, Metadata, HandlerConfig} ->
            ct:fail(specific_executed)
    after 300 ->
        ok
    end.

%% handler can be attached to many events at once
handler_on_multiple_events(Config) ->
    HandlerId = ?config(id, Config),
    Event1 = [a, first, event],
    Event2 = [a, second, event],
    Event3 = [a, third, event],
    Measurements = #{data => 3},
    Metadata = #{some => data},
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,
    telemetry:attach_many(HandlerId, [Event1, Event2, Event3], HandlerFun, HandlerConfig),

    telemetry:execute(Event1, Measurements, Metadata),
    telemetry:execute(Event2, Measurements, Metadata),
    telemetry:execute(Event3, Measurements, Metadata),

    lists:foreach(
        fun(Event) ->
            receive
                {event, Event, Measurements, Metadata, HandlerConfig} ->
                    ok
            after 300 ->
                ct:fail(missing_echo_event)
            end
        end,
        [Event1, Event2, Event3]
    ).

%% handler attached to many events at once can be listed
list_handler_on_many(Config) ->
    HandlerId = ?config(id, Config),
    Event1 = [a, first, event],
    Event2 = [a, second, event],
    Event3 = [a, third, event],
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,

    telemetry:attach_many(HandlerId, [Event1, Event2, Event3], HandlerFun, HandlerConfig),

    lists:foreach(
        fun(Event) ->
            ?assertMatch(
                [
                    #{
                        id := HandlerId,
                        event_name := Event,
                        function := HandlerFun,
                        config := _EventConfig
                    }
                ],
                telemetry:list_handlers(Event)
            )
        end,
        [Event1, Event2, Event3]
    ).

%% handler attached to many events at once is detached from all of them
detach_from_all(Config) ->
    HandlerId = ?config(id, Config),
    Event1 = [a, first, event],
    Event2 = [a, second, event],
    Event3 = [a, third, event],
    HandlerConfig = #{send_to => self()},
    HandlerFun = fun ?MODULE:echo_event/4,

    telemetry:attach_many(HandlerId, [Event1, Event2, Event3], HandlerFun, HandlerConfig),

    telemetry:detach(HandlerId),

    lists:foreach(
        fun(Event) ->
            ?assertEqual([], telemetry:list_handlers(Event))
        end,
        [Event1, Event2, Event3]
    ).

%% execute is safe when the telemetry application is off
off_execute(_Config) ->
    application:stop(telemetry),
    telemetry:execute([event, name], #{}, #{}),
    application:ensure_all_started(telemetry),
    application:stop(telemetry).

%% handler crash propagates to caller
crash_propagates(Config) ->
    HandlerId = ?config(id, Config),
    Event = [a, test, event],
    telemetry:attach(HandlerId, Event, fun ?MODULE:raise_on_event/4, []),

    ?assertException(
        throw,
        got_event,
        telemetry:execute(Event, #{}, #{})
    ).

%% span emits start and stop events and returns the span result
span_emits_start_and_stop(Config) ->
    HandlerId = ?config(id, Config),
    Prefix = [web, request],
    StartMeta = #{route => "/"},
    StopMeta = #{route => "/", status => 200},
    telemetry:attach_many(
        HandlerId,
        [[web, request, start], [web, request, stop]],
        fun ?MODULE:echo_event/4,
        #{send_to => self()}
    ),

    Result = telemetry:span(Prefix, StartMeta, fun() -> {ok, StopMeta} end),

    ?assertEqual(ok, Result),
    receive
        {event, [web, request, start], #{monotonic_time := _, system_time := _}, #{route := "/"},
            _} ->
            ok
    after 1000 ->
        ct:fail(timeout_start)
    end,
    receive
        {event, [web, request, stop], #{duration := D, monotonic_time := _},
            #{route := "/", status := 200},
            _} when
            D >= 0
        ->
            ok
    after 1000 ->
        ct:fail(timeout_stop)
    end.

%% span emits exception event on throw and re-raises
span_emits_exception_on_throw(Config) ->
    HandlerId = ?config(id, Config),
    Prefix = [web, request],
    StartMeta = #{route => "/"},
    telemetry:attach(
        HandlerId,
        [web, request, exception],
        fun ?MODULE:echo_event/4,
        #{send_to => self()}
    ),

    ?assertException(
        throw,
        span_oops,
        telemetry:span(Prefix, StartMeta, fun() -> throw(span_oops) end)
    ),
    receive
        {event, [web, request, exception], #{duration := D, monotonic_time := _},
            #{kind := throw, reason := span_oops, stacktrace := _},
            _} when D >= 0 ->
            ok
    after 1000 ->
        ct:fail(timeout_exception)
    end.

%% span emits exception event on error and re-raises
span_emits_exception_on_error(Config) ->
    HandlerId = ?config(id, Config),
    Prefix = [web, request],
    StartMeta = #{route => "/"},
    telemetry:attach(
        HandlerId,
        [web, request, exception],
        fun ?MODULE:echo_event/4,
        #{send_to => self()}
    ),

    ?assertException(
        error,
        span_crash,
        telemetry:span(Prefix, StartMeta, fun() -> error(span_crash) end)
    ),
    receive
        {event, [web, request, exception], #{duration := D, monotonic_time := _},
            #{kind := error, reason := span_crash, stacktrace := _},
            _} when D >= 0 ->
            ok
    after 1000 ->
        ct:fail(timeout_exception)
    end.

%% helpers

echo_event(Event, Measurements, Metadata, #{send_to := Pid} = Config) ->
    Pid ! {event, Event, Measurements, Metadata, Config}.

raise_on_event(_, _, _, _) ->
    throw(got_event).
