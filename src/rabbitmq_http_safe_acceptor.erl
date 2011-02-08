-module(rabbitmq_http_safe_acceptor).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-record(state, {channel}).

start_link() ->
  gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
  {ok, Connection} = amqp_connection:start(direct),
  {ok, Channel} = amqp_connection:open_channel(Connection),
  {ok, #state{channel = Channel}}.

handle_call(_Msg, _From, State) ->
  {reply, ok, State}.

handle_cast(_, State) ->
    {noreply,State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, #state{channel = Channel}) ->
    amqp_channel:close(Channel),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
