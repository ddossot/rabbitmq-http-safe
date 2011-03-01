{application, rabbitmq_http_safe,
 [{description, "A store and forward HTTP gateway plug-in for RabbitMQ"},
  {vsn, "2.3.1.0"},
  {modules, [
    rabbitmq_http_safe,
    rabbitmq_http_safe_sup,
    rabbitmq_http_safe_acceptor
  ]},
  {registered, []},
  {mod, {rabbitmq_http_safe, []}},
  {env, []},
  {applications, [kernel, stdlib, rabbit, amqp_client, ibrowse]}]}.

