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
  % FIXME support TARGET_RETRY_INTERVAL_HEADER, if TARGET_MAX_RETRIES_HEADER > 0
  
  io:format("~n~1024p~n", [build_http_request(Req)]),
  
  handle(Req,
         Req:get_header_value(?TARGET_URI_HEADER),
         Req:get_header_value(?MAX_RETRIES_HEADER)).
         
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
  build_http_request(HeaderFuns, [{retry_count, 0},
                                   get_method(Req),
                                   get_headers(Req),
                                   get_body(Req)]).

build_http_request([], HttpRequest) ->
  {ok, {http_request, lists:flatten(HttpRequest)}};
build_http_request([HeaderFun|HeaderFuns], Headers) ->
  case HeaderFun(Headers) of
    Error = {error, _} ->
      Error;
    Header ->
      build_http_request(HeaderFuns, [Header|Headers])
  end.

error_missing_header(HeaderName) when is_list(HeaderName) ->
  {error, "Missing mandatory header: " ++ HeaderName}.

error_invalid_header(HeaderName) when is_list(HeaderName) ->
  {error, "Invalid value for header: " ++ HeaderName}.
  
handle(Req, undefined, _) ->
  Req:respond({400, [], "Missing mandatory header: " ++ ?TARGET_URI_HEADER});
handle(Req, _, undefined) ->
  Req:respond({400, [], "Missing mandatory header: " ++ ?MAX_RETRIES_HEADER});
handle(Req, TargetUri, MaxRetriesString)
  when is_list(TargetUri), is_list(MaxRetriesString) ->
  handle(Req, TargetUri, catch(list_to_integer(MaxRetriesString)));
handle(Req, TargetUri, MaxRetries)
  when is_list(TargetUri), is_integer(MaxRetries) ->
  CorrelationId = rabbit_guid:string_guid("safe-"),
  gen_server:cast(?SERVER,
                  {http_request, [
                                  {correlation_id, CorrelationId},
                                  {target_uri, TargetUri},
                                  {max_retries, MaxRetries},
                                  {retry_count, 0},
                                  get_method(Req),
                                  get_headers(Req),
                                  get_body(Req)
                                 ]}),
  % TODO support HTTP version
  Req:respond({204, [{?CID_HEADER, CorrelationId}], []});
handle(Req, _, MaxRetries)
  when is_integer(MaxRetries) ->
  Req:respond({400, [], "Invalid value for header: " ++ ?TARGET_URI_HEADER});
handle(Req, TargetUri, _)
  when is_list(TargetUri) ->
  Req:respond({400, [], "Invalid value for header: " ++ ?MAX_RETRIES_HEADER}).

get_method(Req) ->
  {method, list_to_atom(string:to_lower(atom_to_list(Req:get(method))))}.

get_headers(Req) ->
  MochiwebHeaders = mochiweb_headers:to_list(Req:get(headers)),
  {headers, [{to_list(K) , V} || {K,V} <- MochiwebHeaders]}.

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

handle_cast(HttpRequest = {http_request, Fields}, State=#state{channel = Channel})
  when is_list(Fields)->
  
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

