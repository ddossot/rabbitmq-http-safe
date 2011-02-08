-module(rabbitmq_http_safe).

-export([start/2, stop/1]).

-define(PREFIX, "http-safe").

start(normal, []) ->
  % TODO move to router module
  rabbit_mochiweb:register_context_handler(?PREFIX,
                                           fun(Req) ->
                                             io:format("~1024p~n", [Req]),
                                             Req:ok({200, [{"Content-Type", "text/plain"}], "@@@ HTTP SAFE @@@"})
                                           end,
                                           "HTTP SAFE"),

  rabbitmq_http_safe_sup:start_link().

stop(_State) ->
  ok.
