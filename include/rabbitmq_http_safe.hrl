%%%
%%% @doc HTTP SAFE includes
%%% @author David Dossot <david@dossot.net>
%%%
%%% See LICENSE for license information.
%%% Copyright (c) 2011 David Dossot
%%%

-define(USERNAME, <<"http_safe_user">>).
-define(PASSWORD, <<"http_safe_pwd">>).
-define(VHOST, <<"http_safe">>).

-define(CONNECTION_PARAMS, #amqp_params{username = ?USERNAME,
                                        password = ?PASSWORD,
                                        virtual_host = ?VHOST}).

-define(PENDING_REQUESTS_EXCHANGE, <<"pending_requests">>).

-define(DECLARE_PENDING_REQUESTS_EXCHANGE, #'exchange.declare'{exchange = ?PENDING_REQUESTS_EXCHANGE,
                                                               type = <<"fanout">>,
                                                               durable = true,
                                                               auto_delete = false}).
