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

-export([start_link/0, handle/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(SERVER, ?MODULE).

-record(state, {connection, channel}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).
  
handle(Req) ->
  case build_http_request(Req) of
    {ok, CorrelationId, HttpRequest} ->
      gen_server:cast(?SERVER, HttpRequest),
      Req:respond({204, [{?CID_HEADER, CorrelationId}], []});
    {error, Cause} ->
      Req:respond({400, [], Cause})
  end.
         
build_http_request(Req) ->
  % build the internal HTTP request representation by applying a succession of functions to the incoming request
  % any function that returns {error, Cause} breaks the building process
  
  TargetUriFun =
    fun(_) ->
      case Req:get_header_value(?TARGET_URI_HEADER) of
        undefined ->
          error_missing_header(?TARGET_URI_HEADER);
        TargetUri ->
          {target_uri, TargetUri}
       end
    end,
  
  AcceptRegexFun =
    fun(_) ->
      case Req:get_header_value(?ACCEPT_REGEX_HEADER) of
        undefined ->
          error_missing_header(?ACCEPT_REGEX_HEADER);
        AcceptRegex ->
          case re:compile(AcceptRegex) of
            {ok, _} ->
              {accept_regex, AcceptRegex};
            _ ->
              error_invalid_header(?ACCEPT_REGEX_HEADER)
          end
       end
    end,
  
  MaxRetriesFun =
    fun(_) ->
      case Req:get_header_value(?MAX_RETRIES_HEADER) of
        undefined ->
          {max_retries, 0};
        MaxRetriesString ->
          try list_to_integer(MaxRetriesString) of
            MaxRetries when MaxRetries >= 0 ->
              {max_retries, MaxRetries};
            _ ->
              error_invalid_header(?MAX_RETRIES_HEADER)
          catch
            _:_ ->
              error_invalid_header(?MAX_RETRIES_HEADER)
          end
      end
    end,
  
  RetryIntervalFun =
    fun(Headers) ->
      case proplists:get_value(max_retries, Headers) of
        0 ->
          undefined;
        _ ->
          try list_to_integer(Req:get_header_value(?RETRY_INTERVAL_HEADER)) of
            RetryInterval when RetryInterval > 0 andalso RetryInterval =< 60 ->
              {retry_interval, RetryInterval};
            _ ->
              error_invalid_header(?RETRY_INTERVAL_HEADER)
          catch
            _:_ ->
              error_invalid_header(?RETRY_INTERVAL_HEADER)
          end
      end
    end,
  
  HeaderFuns = [TargetUriFun, AcceptRegexFun, MaxRetriesFun, RetryIntervalFun],
  
  case build_http_request_props(HeaderFuns, []) of
    Error = {error, _} ->
      Error;
    {ok, Props} ->
      CorrelationId = rabbit_guid:string_guid("safe-"),
      % TODO support HTTP version(?)
      {ok, CorrelationId, {http_request, [{correlation_id, CorrelationId},
                                          {retry_count, 0},
                                          get_method(Req),
                                          get_headers(Req),
                                          get_body(Req)] ++ Props}}
  end.

build_http_request_props([], HttpRequest) ->
  {ok, lists:flatten(HttpRequest)};
build_http_request_props([HeaderFun|HeaderFuns], Headers) ->
  case HeaderFun(Headers) of
    Error = {error, _} ->
      Error;
    Header ->
      build_http_request_props(HeaderFuns, [Header|Headers])
  end.

error_missing_header(HeaderName) when is_list(HeaderName) ->
  {error, "Missing mandatory header: " ++ HeaderName}.

error_invalid_header(HeaderName) when is_list(HeaderName) ->
  {error, "Invalid value for header: " ++ HeaderName}.

get_method(Req) ->
  {method, list_to_atom(string:to_lower(atom_to_list(Req:get(method))))}.

get_headers(Req) ->
  MochiwebHeaders = mochiweb_headers:to_list(Req:get(headers)),
  
  NotPropagatedHeadersLower = [string:to_lower(H) || H <- ?NOT_PROPAGATED_HEADERS],
  
  Headers =
    lists:foldl(
      fun({Name, Value}, Acc) ->
        NameAsString = to_list(Name),
        case lists:member(string:to_lower(NameAsString), NotPropagatedHeadersLower) of
          true ->
            Acc;
          false ->
            [{NameAsString, Value} | Acc]
        end
      end,
      [],
      MochiwebHeaders),
      
  {headers, lists:flatten(Headers)}.

to_list(K) when is_atom(K) ->
  atom_to_list(K);
to_list(K) when is_binary(K) ->
  binary_to_list(K);
to_list(K) when is_list(K) ->
  K.
  
get_body(Req) ->
  {body, extract_body(Req:recv_body())}.
extract_body(undefined) ->
  <<>>;
extract_body(Body) ->
  Body.
  
%---------------------------
% Gen Server Implementation
% --------------------------

init([]) ->
  {ok, Connection} = amqp_connection:start(direct, ?CONNECTION_PARAMS),
  {ok, Channel} = amqp_connection:open_channel(Connection),
  
  amqp_channel:call(Channel, ?DECLARE_PENDING_REQUESTS_EXCHANGE),
  
  {ok, #state{connection = Connection, channel = Channel}}.

handle_call(InvalidMessage, _From, State) ->
  {reply, {error, {invalid_message, InvalidMessage}}, State}.

handle_cast(HttpRequest = {http_request, Props}, State=#state{channel = Channel})
  when is_list(Props)->
  
  Properties = #'P_basic'{content_type = ?ERLANG_BINARY_TERM_CONTENT_TYPE,
                          delivery_mode = 2},
  BasicPublish = #'basic.publish'{exchange = ?PENDING_REQUESTS_EXCHANGE},
  Content = #amqp_msg{props = Properties, payload = term_to_binary(HttpRequest)},
  amqp_channel:call(Channel, BasicPublish, Content),
  
  {noreply, State};

handle_cast(_, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_, #state{connection = Connection, channel = Channel}) ->
  catch amqp_channel:close(Channel),
  catch amqp_connection:close(Connection),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

