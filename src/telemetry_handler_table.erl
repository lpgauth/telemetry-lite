-module(telemetry_handler_table).

-behaviour(gen_server).

-export([
    start_link/0,
    insert/4,
    delete/1,
    list_by_prefix/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-include("telemetry.hrl").

-record(state, {
    handlers = #{} :: #{telemetry:event_name() => [#handler{}]},
    ids = #{} :: #{telemetry:handler_id() => [telemetry:event_name()]}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec insert(
    telemetry:handler_id(),
    [telemetry:event_name()],
    telemetry:handler_function(),
    telemetry:handler_config()
) ->
    ok | {error, already_exists}.
insert(HandlerId, EventNames, Function, Config) ->
    gen_server:call(?MODULE, {insert, HandlerId, EventNames, Function, Config}).

-spec delete(telemetry:handler_id()) -> ok | {error, not_found}.
delete(HandlerId) ->
    gen_server:call(?MODULE, {delete, HandlerId}).

-spec list_by_prefix(telemetry:event_prefix()) -> [#handler{}].
list_by_prefix(EventPrefix) ->
    gen_server:call(?MODULE, {list_by_prefix, EventPrefix}).

%% gen_server callbacks

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call(
    {insert, HandlerId, EventNames, Function, Config},
    _From,
    #state{handlers = Handlers, ids = Ids} = State
) ->
    case maps:is_key(HandlerId, Ids) of
        true ->
            {reply, {error, already_exists}, State};
        false ->
            {Handlers2, Ids2} = lists:foldl(
                fun(EventName, {HAcc, IAcc}) ->
                    Handler = #handler{
                        id = HandlerId,
                        event_name = EventName,
                        function = Function,
                        config = Config
                    },
                    List = maps:get(EventName, HAcc, []),
                    NewList = List ++ [Handler],
                    persistent_term:put({telemetry, EventName}, to_fc(NewList)),
                    {HAcc#{EventName => NewList}, IAcc#{
                        HandlerId => maps:get(HandlerId, IAcc, []) ++ [EventName]
                    }}
                end,
                {Handlers, Ids},
                EventNames
            ),
            {reply, ok, State#state{handlers = Handlers2, ids = Ids2}}
    end;
handle_call(
    {delete, HandlerId},
    _From,
    #state{handlers = Handlers, ids = Ids} = State
) ->
    case maps:take(HandlerId, Ids) of
        error ->
            {reply, {error, not_found}, State};
        {EventNames, Ids2} ->
            Handlers2 = lists:foldl(
                fun(EventName, HAcc) ->
                    List = [
                        H
                     || H <- maps:get(EventName, HAcc, []),
                        H#handler.id =/= HandlerId
                    ],
                    case List of
                        [] ->
                            persistent_term:erase({telemetry, EventName}),
                            maps:remove(EventName, HAcc);
                        _ ->
                            persistent_term:put({telemetry, EventName}, to_fc(List)),
                            HAcc#{EventName := List}
                    end
                end,
                Handlers,
                EventNames
            ),
            {reply, ok, State#state{handlers = Handlers2, ids = Ids2}}
    end;
handle_call({list_by_prefix, EventPrefix}, _From, #state{handlers = Handlers} = State) ->
    Result = maps:fold(
        fun(EventName, HandlerList, Acc) ->
            case lists:prefix(EventPrefix, EventName) of
                true -> HandlerList ++ Acc;
                false -> Acc
            end
        end,
        [],
        Handlers
    ),
    {reply, Result, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{handlers = Handlers}) ->
    maps:foreach(
        fun(EventName, _) ->
            persistent_term:erase({telemetry, EventName})
        end,
        Handlers
    ),
    ok.

%%

to_fc(Handlers) ->
    [{F, C} || #handler{function = F, config = C} <- Handlers].
