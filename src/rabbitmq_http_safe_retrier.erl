%%%
%%% @doc HTTP SAFE - Request Retrier
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-module(rabbitmq_http_safe_retrier).
-behaviour(gen_cron).

-include("rabbitmq_http_safe.hrl").

-export([start_link/0]).
-export([init/1, handle_tick/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(SERVER, ?MODULE).

start_link() ->
  gen_cron:start_link({local, ?SERVER}, ?MODULE, ?RETRY_INTERVAL_MILLIS,[], []).
  
%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
  {ok, Connection} = amqp_connection:start(direct, ?CONNECTION_PARAMS),
  {ok, Channel} = amqp_connection:open_channel(Connection),
  
  amqp_channel:call(Channel, ?DECLARE_RETRY_REQUESTS_EXCHANGE),
  
  lists:foreach(
    fun(Minute) ->
      MinuteQueue = get_minute_queue(Minute),
      
      amqp_channel:call(Channel, #'queue.declare'{queue = MinuteQueue,
                                                  durable = true,
                                                  auto_delete = false}),
  
      amqp_channel:call(Channel, #'queue.bind'{queue = MinuteQueue,
                                               routing_key = list_to_binary(integer_to_list(Minute)),
                                               exchange = ?RETRY_REQUESTS_EXCHANGE})
    end,
    lists:seq(0, 59)),
  
  catch amqp_channel:close(Channel),
  catch amqp_connection:close(Connection),
  {ok, stateless}.
  
handle_tick(_Reason, _State) ->
  % FIXME spawn a process that moves all current minute retry messages to main exchange
  {ok, Connection} = amqp_connection:start(direct, ?CONNECTION_PARAMS),
  {ok, Channel} = amqp_connection:open_channel(Connection),
    
  #'tx.select_ok'{} = amqp_channel:call(Channel, #'tx.select'{}),
  
  MinuteQueue = get_minute_queue(get_current_minute()),
  drain_to_pending_request(MinuteQueue, Channel),

  #'tx.commit_ok'{} = amqp_channel:call(Channel, #'tx.commit'{}),
  
  catch amqp_channel:close(Channel),
  catch amqp_connection:close(Connection),
  ok.

handle_call(InvalidMessage, _From, State) ->
  {reply, {error, {invalid_message, InvalidMessage}}, State}.

handle_cast(_, State) ->
  {noreply, State}.

handle_info(_, State) ->
  {noreply, State}.

terminate(_, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%---------------------------
% Support Functions
% --------------------------
get_minute_queue(Minute) ->
  list_to_binary("retry_requests_" ++ integer_to_list(Minute) ++ ".queue").
  
get_current_minute() ->
  {_,{_,CurrentMinute,_}} = calendar:now_to_datetime(erlang:now()),
  CurrentMinute.

drain_to_pending_request(MinuteQueue, Channel) ->
  case amqp_channel:call(Channel, #'basic.get'{queue = MinuteQueue, no_ack = true}) of
    {#'basic.get_ok'{}, Message} ->
      BasicPublish = #'basic.publish'{exchange = ?PENDING_REQUESTS_EXCHANGE},
      amqp_channel:call(Channel, BasicPublish, Message);
    _ ->
      ok
  end.

