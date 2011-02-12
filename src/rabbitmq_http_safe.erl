%%%
%%% @doc HTTP SAFE - Main
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-module(rabbitmq_http_safe).

-include("rabbitmq_http_safe.hrl").

-export([start/2, stop/1]).

-define(PREFIX, "http-safe").

start(normal, []) ->
  rabbitmq_setup(),

  rabbit_mochiweb:register_context_handler(?PREFIX,
                                           fun rabbitmq_http_safe_acceptor:handle/1,
                                           "HTTP SAFE"),

  rabbitmq_http_safe_sup:start_link().

stop(_State) ->
  ok.
  
%% Private Functions
rabbitmq_setup() ->
  create_vhost_if_needed(),
  create_user_if_needed(),
  set_user_permissions(),
  ok.

create_vhost_if_needed() ->
  case rabbit_vhost:exists(?VHOST) of
    true  -> ok;
    false -> rabbit_vhost:add(?VHOST)
  end.

create_user_if_needed() ->
  case rabbit_auth_backend_internal:lookup_user(?USERNAME) of
    {ok, _} ->
      ok;
    {error,not_found} ->
      rabbit_auth_backend_internal:add_user(?USERNAME, ?PASSWORD)
  end.

set_user_permissions() ->
  rabbit_auth_backend_internal:set_permissions(?USERNAME, ?VHOST , <<".*">>, <<".*">>, <<".*">>).

