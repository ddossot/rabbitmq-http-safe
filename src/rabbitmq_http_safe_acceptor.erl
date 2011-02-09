%%%
%%% @doc HTTP SAFE - Request Acceptor
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-module(rabbitmq_http_safe_acceptor).
-behaviour(gen_server).

-include("rabbitmq_http_safe.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-record(state, {connection, channel}).

start_link() ->
  gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
  {ok, Connection} = amqp_connection:start(direct, ?CONNECTION_PARAMS),
  {ok, Channel} = amqp_connection:open_channel(Connection),
  
  amqp_channel:call(Channel, ?DECLARE_PENDING_REQUESTS_EXCHANGE),
  
  {ok, #state{connection = Connection, channel = Channel}}.

handle_call(_Msg, _From, State) ->
  {reply, ok, State}.

handle_cast(_, State) ->
  {noreply,State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_, #state{connection = Connection, channel = Channel}) ->
  catch amqp_channel:close(Channel),
  catch amqp_connection:close(Connection),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
