-module(telemetry).

-moduledoc "Lightweight telemetry event dispatching. Optimized for `execute/3` throughput.".

-export([
    attach/4,
    attach_many/4,
    detach/1,
    execute/2,
    execute/3,
    list_handlers/1,
    span/3
]).

-include("telemetry.hrl").

-type handler_id() :: term().
-type event_name() :: [atom(), ...].
-type event_measurements() :: map().
-type event_metadata() :: map().
-type event_prefix() :: [atom()].
-type handler_config() :: term().
-type handler_function() :: fun(
    (event_name(), event_measurements(), event_metadata(), handler_config()) -> any()
).
-type span_function() :: fun(() -> {term(), event_metadata()}).
-type handler() :: #{
    id := handler_id(),
    event_name := event_name(),
    function := handler_function(),
    config := handler_config()
}.

-export_type([
    handler_id/0,
    event_name/0,
    event_measurements/0,
    event_metadata/0,
    event_prefix/0,
    handler_config/0,
    handler_function/0,
    span_function/0,
    handler/0
]).

-doc "Attaches the handler to the event. Returns `{error, already_exists}` if a handler with the same ID is already attached.".
-spec attach(handler_id(), event_name(), handler_function(), handler_config()) ->
    ok | {error, already_exists}.
attach(HandlerId, EventName, Function, Config) ->
    attach_many(HandlerId, [EventName], Function, Config).

-doc "Attaches the handler to multiple events. Detaching removes it from all of them.".
-spec attach_many(handler_id(), [event_name()], handler_function(), handler_config()) ->
    ok | {error, already_exists}.
attach_many(HandlerId, EventNames, Function, Config) ->
    telemetry_handler_table:insert(HandlerId, EventNames, Function, Config).

-doc "Removes the handler. Returns `{error, not_found}` if no handler with the given ID exists.".
-spec detach(handler_id()) -> ok | {error, not_found}.
detach(HandlerId) ->
    telemetry_handler_table:delete(HandlerId).

-doc "Same as `execute(EventName, Measurements, #{})`.".
-spec execute(event_name(), event_measurements()) -> ok.
execute(EventName, Measurements) ->
    execute(EventName, Measurements, #{}).

-doc "Emits the event, invoking all attached handlers. Handler crashes propagate to the caller.".
-spec execute(event_name(), event_measurements(), event_metadata()) -> ok.
execute([_ | _] = EventName, Measurements, Metadata) when is_map(Measurements), is_map(Metadata) ->
    do_execute(persistent_term:get({telemetry, EventName}, []), EventName, Measurements, Metadata).

-doc "Executes the span function, emitting start/stop/exception events. The span function must return `{Result, StopMetadata}` — any other return value is treated as an exception, fires the exception event, and re-raises as a `case_clause` error.".
-spec span(event_prefix(), event_metadata(), span_function()) -> term().
span(EventPrefix, StartMetadata, SpanFunction) ->
    StartTime = erlang:monotonic_time(),
    execute(
        EventPrefix ++ [start],
        #{monotonic_time => StartTime, system_time => erlang:system_time()},
        StartMetadata
    ),
    try SpanFunction() of
        {Result, StopMetadata} ->
            StopTime = erlang:monotonic_time(),
            execute(
                EventPrefix ++ [stop],
                #{duration => StopTime - StartTime, monotonic_time => StopTime},
                StopMetadata
            ),
            Result
    catch
        Class:Reason:Stacktrace ->
            StopTime = erlang:monotonic_time(),
            execute(
                EventPrefix ++ [exception],
                #{duration => StopTime - StartTime, monotonic_time => StopTime},
                StartMetadata#{kind => Class, reason => Reason, stacktrace => Stacktrace}
            ),
            erlang:raise(Class, Reason, Stacktrace)
    end.

-doc "Returns all handlers matching the given event prefix.".
-spec list_handlers(event_prefix()) -> [handler()].
list_handlers(EventPrefix) ->
    [
        #{
            id => Id,
            event_name => EventName,
            function => Function,
            config => Config
        }
     || #handler{
            id = Id,
            event_name = EventName,
            function = Function,
            config = Config
        } <- telemetry_handler_table:list_by_prefix(EventPrefix)
    ].

%% internal

do_execute([], _, _, _) ->
    ok;
do_execute([{F, C} | Rest], EventName, Measurements, Metadata) ->
    F(EventName, Measurements, Metadata, C),
    do_execute(Rest, EventName, Measurements, Metadata).
