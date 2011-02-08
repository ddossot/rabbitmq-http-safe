-module(rabbitmq_http_safe_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, _Arg = []).

init([]) ->
  {ok, {{one_for_one, 3, 10},
        [{rabbitmq_http_safe_acceptor,
          {rabbitmq_http_safe_acceptor, start_link, []},
          permanent,
          10000,
          worker,
          [rabbitmq_http_safe_acceptor]}
        ]}}.
