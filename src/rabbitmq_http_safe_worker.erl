-module(rabbitmq_http_safe_worker).
-behaviour(gen_server).

-export([start/0, start/2, stop/0, stop/1, start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-record(state, {}).

start() ->
  start_link(),
  ok.

start(normal, []) ->
  start_link().

stop() ->
  ok.

stop(_State) ->
  stop().

start_link() ->
  gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
  {ok, #state{}}.

handle_call(_Msg, _From, State) ->
  {reply, ok, State}.

handle_cast(_, State) ->
    {noreply,State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
