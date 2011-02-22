%%%
%%% @doc HTTP SAFE - Request Dispatcher
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-module(rabbitmq_http_safe_dispatcher).
-behaviour(gen_server).

-include("rabbitmq_http_safe.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(SERVER, ?MODULE).

-record(state, {connection, channel}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).
  
%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
  {ok, Connection} = amqp_connection:start(direct, ?CONNECTION_PARAMS),
  {ok, Channel} = amqp_connection:open_channel(Connection),
  
  amqp_channel:call(Channel, ?DECLARE_PENDING_REQUESTS_EXCHANGE),
  
  amqp_channel:call(Channel, #'queue.declare'{queue = ?PENDING_REQUESTS_QUEUE,
                                              durable = true,
                                              auto_delete = false}),
  
  amqp_channel:call(Channel, #'queue.bind'{queue = ?PENDING_REQUESTS_QUEUE,
                                           exchange = ?PENDING_REQUESTS_EXCHANGE}),
                                           

  % we want a strict flow control
  amqp_channel:call(Channel, #'basic.qos'{prefetch_count = 0}),
                                           
  amqp_channel:subscribe(Channel, #'basic.consume'{queue = ?PENDING_REQUESTS_QUEUE,
                                                   no_ack = false},
                         self()),
  
  {ok, #state{connection = Connection, channel = Channel}}.

handle_call(InvalidMessage, _From, State) ->
  {reply, {error, {invalid_message, InvalidMessage}}, State}.

handle_cast(_, State) ->
  {noreply, State}.

handle_info({#'basic.deliver'{delivery_tag = Tag}, #amqp_msg{payload = Payload}},
            State=#state{channel = Channel}) ->
  
  dispatch(binary_to_term(Payload), Channel),
  
  amqp_channel:call(Channel, #'basic.ack'{delivery_tag = Tag}),
  {noreply, State};

handle_info(_, State) ->
  {noreply, State}.

terminate(_, #state{connection = Connection, channel = Channel}) ->
  catch amqp_channel:close(Channel),
  catch amqp_connection:close(Connection),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%---------------------------
% Support Functions
% --------------------------
dispatch(HttpRequest = {http_request, Props}, Channel) ->
  
  CorrelationId = proplists:get_value(correlation_id, Props),
  
  TargetUri = proplists:get_value(target_uri, Props),
  Headers = proplists:get_value(headers, Props) ++ [{?CID_HEADER, CorrelationId}],
  Method = proplists:get_value(method, Props),
  Body = proplists:get_value(body, Props),
  
  DispatchResult = (catch ibrowse:send_req(TargetUri, Headers, Method, Body)),
  
  handle_dispatch_result(DispatchResult,
                         HttpRequest,
                         Channel).
  
handle_dispatch_result({ok, Status, _, _}, HttpRequest = {http_request, Props}, Channel) ->
  AcceptRegexString = proplists:get_value(accept_regex, Props),
  {ok, AcceptRegex} = re:compile(AcceptRegexString),
  case re:run(Status, AcceptRegex) of
    nomatch ->
      handle_failed_dispatch({error, Status ++ " didn't match accept regex: " ++ AcceptRegexString},
                             HttpRequest,
                             Channel);
    _ ->
      handle_successfull_dispatch(HttpRequest)
  end;
handle_dispatch_result(Error, HttpRequest, Channel) ->
  handle_failed_dispatch(Error, HttpRequest, Channel).

handle_failed_dispatch(Error, HttpRequest, Channel) ->
  % FIXME implement missing features:
  % - check if max attempt has been reached
  %  - if yes, route failure if a callback URI exists
  % - else send to retrying exchange with rkey=current sec + try interval
  error_logger:error_msg("Failed to dispatch: ~p with error: ~p", [HttpRequest, Error]).
  
handle_successfull_dispatch({http_request, Props}) ->
  case proplists:get_value(callback_uri, Props) of
    CallbackUri when is_list(CallbackUri) ->
      % FIXME build JSON success message
      rabbitmq_http_safe_acceptor:dispatch({http_request, [proplists:lookup(correlation_id, Props),
                                                           {accept_regex, ".*"},
                                                           {target_uri, CallbackUri},
                                                           {headers, [{?STATUS_HEADER, "success"}]},
                                                           {method, post},
                                                           {body, <<"SUCCESS!!!">>}
                                                           ]});
    _ ->
      ok
  end.

