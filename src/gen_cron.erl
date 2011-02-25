%% @doc Provides a gen_server-like interface to periodic execution.
%% The {@link handle_tick/2} callback is executed in a seperate 
%% process periodically or in response to a {@link force_run/1} command.
%% Only one instance of a spawned handle_tick/2 is allowed at any time.
%% @end

-module (gen_cron).
-export ([ force_run/1,
           start/4,
           start/5,
           start_link/4,
           start_link/5 ]).
%-behaviour (behaviour).
-export ([ behaviour_info/1 ]).
-behaviour (gen_server).
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           terminate/2,
           code_change/3 ]).
-export ([ handle_tick/2 ]).

-include_lib ("eunit/include/eunit.hrl").

-record (gencron, { module,
                    mref = undefined,
                    pid = undefined,
                    state }).

-record (gencronv2, { module,
                      interval,
                      mref = undefined,
                      pid = undefined,
                      state }).

-oldrecord (gencron).

-define (is_interval (X), (((X) =:= infinity) orelse 
                           (is_integer (X) andalso (X) > 0) orelse
                           (is_tuple (X) andalso 
                            element (1, X) =:= cluster andalso
                            is_integer (element (2, X)) andalso
                            element (2, X) > 0))).

%% @type interval () = integer () | { cluster, integer () }.  One can specify a 
%% cluster-scaled interval, in which case the 2nd element of the tuple
%% is (dynamically) multiplied by the number of nodes 
%% length ([node () | nodes ()]).
%% @end

%-=====================================================================-
%-                                Public                               -
%-=====================================================================-

%% @hidden

behaviour_info (callbacks) ->
  [ { init, 1 },
    { handle_call, 3 },
    { handle_cast, 2 },
    { handle_info, 2 },
    { terminate, 2 },
    { code_change, 3 },
    { handle_tick, 2 } ];
behaviour_info (_Other) ->
  undefined.

%% @spec force_run (ServerRef) -> { ok, Pid } | { underway, Pid }
%% @doc Schedule an immediate execution.  If the process is already
%% executing then { underway, Pid } is returned.
%% @end

force_run (ServerRef) ->
  gen_server:call (ServerRef, { ?MODULE, force_run }).

%% @spec start (Module, Interval::interval (), Args, Options) -> Result
%% @doc The analog to gen_server:start/3.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end

start (Module, Interval, Args, Options) when ?is_interval (Interval) ->
  gen_server:start (?MODULE, [ Module, Interval | Args ], Options).

%% @spec start (ServerName, Module, Interval::interval (), Args, Options) -> Result
%% @doc The analog to gen_server:start/4.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end

start (ServerName, Module, Interval, Args, Options) when ?is_interval (Interval) ->
  gen_server:start (ServerName, ?MODULE, [ Module, Interval | Args ], Options).

%% @spec start_link (Module, Interval::interval (), Args, Options) -> Result
%% @doc The analog to gen_server:start_link/3.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end

start_link (Module, Interval, Args, Options) when ?is_interval (Interval) ->
  gen_server:start_link (?MODULE, [ Module, Interval | Args ], Options).

%% @spec start_link (ServerName, Module, Interval::interval (), Args, Options) -> Result
%% @doc The analog to gen_server:start_link/4.  Takes an extra argument
%% Interval which is the periodic execution interval in milliseconds.
%% @end

start_link (ServerName, Module, Interval, Args, Options) when ?is_interval (Interval) ->
  gen_server:start_link (ServerName, 
                         ?MODULE,
                         [ Module, Interval | Args ],
                         Options).

%-=====================================================================-
%-                         gen_server callbacks                        -
%-=====================================================================-

%% @spec init (Args) -> result ()
%% @doc Just like the gen_server version.
%% @end

init ([ Module, Interval | Args ]) ->
  process_flag (trap_exit, true),

  case Module:init (Args) of
    { ok, State } ->
      reset_timer (Interval),

      { ok, #gencronv2{ interval = Interval, module = Module, state = State } };
    { ok, State, Timeout } ->
      reset_timer (Interval),

      { ok,
        #gencronv2{ interval = Interval, module = Module, state = State },
        Timeout };
    R ->
      R
  end.

%% @spec handle_call (Request, From, State) -> Result
%% @doc Just like the gen_server version, except that 
%% the force_run call is intercepted and handled.
%% @end

handle_call ({ ?MODULE, force_run }, 
             _From,
             State = #gencronv2{ pid = undefined }) ->
  { Pid, MRef } = erlang:spawn_monitor (State#gencronv2.module,
                                        handle_tick,
                                        [ force, State#gencronv2.state ]),
  { reply, { ok, Pid }, State#gencronv2{ pid = Pid, mref = MRef } };
handle_call ({ ?MODULE, force_run }, _From, State) ->
  { reply, { underway, State#gencronv2.pid }, State };
handle_call (Request, From, State) ->
  wrap ((State#gencronv2.module):handle_call (Request,
                                              From,
                                              State#gencronv2.state),
        State).

%% @spec handle_cast (Request, State) -> Result
%% @doc Just like the gen_server version.
%% @end

handle_cast (Request, State) ->
  wrap ((State#gencronv2.module):handle_cast (Request, State#gencronv2.state),
        State).

%% @spec handle_info (Msg, State) -> Result
%% @doc Just like the gen_server version, except that 
%% messages related to spawned process monitor are intercepted and
%% handled (and forwarded to the callback module in a { tick_monitor, Msg }
%% tuple), and messages related to the periodic timer are handled 
%% (and not forwarded to the callback module).
%% @end

handle_info (Msg = { 'DOWN', MRef, _, _, _ }, 
             State = #gencronv2{ mref = MRef }) ->
  handle_info ({ tick_monitor, Msg },
               State#gencronv2{ pid = undefined, mref = undefined });
handle_info ({ ?MODULE, tick }, State = #gencronv2{ mref = undefined }) ->
  reset_timer (State#gencronv2.interval),

  { Pid, MRef } = erlang:spawn_monitor (State#gencronv2.module,
                                        handle_tick,
                                        [ tick, State#gencronv2.state ]),

  { noreply, State#gencronv2{ pid = Pid, mref = MRef } };
handle_info ({ ?MODULE, tick }, State) ->
  reset_timer (State#gencronv2.interval),

  { noreply, State };
handle_info (Msg, State) ->
  wrap ((State#gencronv2.module):handle_info (Msg, State#gencronv2.state),
        State).

%% @spec terminate (Result, State) -> Result
%% @doc Just like the gen_server version, except that 
%% if a process is running, we wait for it to terminate
%% (prior to calling the module's terminate).
%% @end

terminate (Reason, State) ->
  NewState = 
    case State#gencronv2.mref of
      undefined -> 
        State#gencronv2.state;
      MRef -> 
        exit (State#gencronv2.pid, Reason),
        receive Msg = { 'DOWN', MRef, _, _, _ } -> 
          case (State#gencronv2.module):handle_info ({ tick_monitor, Msg }, 
                                                     State#gencronv2.state) of
            { noreply, NS } -> NS;
            { noreply, NS, _ } -> NS;
            { stop, _, NS } -> NS
          end
        end
    end,
  (State#gencronv2.module):terminate (Reason, NewState).

%% @spec code_change (OldVsn, State, Extra) -> Result
%% @doc Just like the gen_server version.
%% @end

code_change (OldVsn, State = #gencron{}, Extra) -> 
  { ok, NewState } = 
    (State#gencron.module):code_change (OldVsn,
                                        State#gencron.state,
                                        Extra),

  % interval is not really infinity, but the old code
  % used timer:send_interval, so no need to reset the timer;
  % infinity thus works nicely

  { ok, #gencronv2{ module = State#gencron.module,
                    interval = infinity, 
                    mref = State#gencron.mref,
                    pid = State#gencron.pid,
                    state = NewState } };
code_change (OldVsn, State, Extra) -> 
  { ok, NewState } = 
    (State#gencronv2.module):code_change (OldVsn,
                                          State#gencronv2.state,
                                          Extra),
  { ok, State#gencronv2{ state = NewState } }.

%% @spec handle_tick (Reason::reason (), State) -> none ()
%%   reason () = tick | force
%% @doc This is called as a seperate process, either periodically or in
%% response to a force.  The State argument is the server state at 
%% the time of the spawn.

handle_tick (_Reason, _State) ->
  ok.

%-=====================================================================-
%-                               Private                               -
%-=====================================================================-

reset_timer (Interval) ->
  % infinity may seem unnecessary, but we can get here via code_change/3

  case Interval of
    infinity -> ok;
    _ -> { ok, _ } = timer:send_after (tick_interval (Interval), 
                                       { ?MODULE, tick })
  end.

tick_interval (Interval) when is_integer (Interval) -> 
  Interval;
tick_interval ({ cluster, Interval }) when is_integer (Interval) ->
  NodeCount = length ([ node () | nodes () ]),
  Spread = random:uniform (NodeCount),
  (tick_interval (Interval) * 2 * (1 + Spread)) div (3 + NodeCount).

wrap ({ reply, Reply, NewState }, State) ->
  { reply, Reply, State#gencronv2{ state = NewState } };
wrap ({ reply, Reply, NewState, Timeout }, State) ->
  { reply, Reply, State#gencronv2{ state = NewState }, Timeout };
wrap ({ noreply, NewState }, State) ->
  { noreply, State#gencronv2{ state = NewState } };
wrap ({ noreply, NewState, Timeout }, State) ->
  { noreply, State#gencronv2{ state = NewState }, Timeout };
wrap ({ stop, Reason, Reply, NewState }, State) ->
  { stop, Reason, Reply, State#gencronv2{ state = NewState } };
wrap ({ stop, Reason, NewState }, State) ->
  { stop, Reason, State#gencronv2{ state = NewState } }.

-ifdef (EUNIT).

%-=====================================================================-
%-                                Tests                                -
%-=====================================================================-

infinity_test_ () ->
  F = 
    fun (Tab) ->
      fun () ->
        { ok, Pid } = gen_cron:start_link (gen_cron_test,
                                           infinity,
                                           [ Tab ],
                                           [ ]),
  
        MRef = erlang:monitor (process, Pid),
  
        { ok, RunPid } = gen_cron:force_run (Pid),
        { underway, RunPid } = gen_cron:force_run (Pid),
  
        receive after 6500 -> ok end,
  
        exit (Pid, shutdown),
  
        receive
          { 'DOWN', MRef, _, _, _ } -> ok
        end,
  
        ?assert (ets:lookup (Tab, count) =:= [{ count, 0 }]),
        ?assert (ets:lookup (Tab, force) =:= [{ force, 1 }]),
        ?assert (ets:lookup (Tab, mega) =:= []),
        ?assert (ets:lookup (Tab, turg) =:= []),
        true
      end
    end,

    { setup,
      fun () -> ets:new (?MODULE, [ public, set ]) end,
      fun (Tab) -> ets:delete (Tab) end,
      fun (Tab) -> { timeout, 60, F (Tab) } end
    }.

cluster_tick_test_ () ->
  F = 
    fun (Tab) ->
      fun () ->
        { ok, Pid } = gen_cron:start_link (gen_cron_test,
                                           { cluster, 1000 },
                                           [ Tab ],
                                           [ ]),
  
        MRef = erlang:monitor (process, Pid),
  
        { ok, RunPid } = gen_cron:force_run (Pid),
        { underway, RunPid } = gen_cron:force_run (Pid),
  
        receive after 6500 -> ok end,
  
        exit (Pid, shutdown),
  
        receive
          { 'DOWN', MRef, _, _, Info } -> ?assert (Info =:= shutdown)
        end,

        ?assert (ets:lookup (Tab, count) =:= [{ count, 2 }]),
        ?assert (ets:lookup (Tab, force) =:= [{ force, 1 }]),
        ?assert (ets:lookup (Tab, tick_monitor) =:= [{ tick_monitor, 3 }]),
        ?assert (ets:lookup (Tab, mega) =:= []),
        ?assert (ets:lookup (Tab, turg) =:= []),
        true
      end
    end,

    { setup,
      fun () -> ets:new (?MODULE, [ public, set ]) end,
      fun (Tab) -> ets:delete (Tab) end,
      fun (Tab) -> { timeout, 60, F (Tab) } end
    }.


tick_test_ () ->
  F = 
    fun (Tab) ->
      fun () ->
        { ok, Pid } = gen_cron:start_link (gen_cron_test, 1000, [ Tab ], [ ]),
  
        MRef = erlang:monitor (process, Pid),
  
        { ok, RunPid } = gen_cron:force_run (Pid),
        { underway, RunPid } = gen_cron:force_run (Pid),
  
        receive after 6500 -> ok end,
  
        exit (Pid, shutdown),
  
        receive
          { 'DOWN', MRef, _, _, Info } -> ?assert (Info =:= shutdown)
        end,

        ?assert (ets:lookup (Tab, count) =:= [{ count, 2 }]),
        ?assert (ets:lookup (Tab, force) =:= [{ force, 1 }]),
        ?assert (ets:lookup (Tab, tick_monitor) =:= [{ tick_monitor, 3 }]),
        ?assert (ets:lookup (Tab, mega) =:= []),
        ?assert (ets:lookup (Tab, turg) =:= []),
        true
      end
    end,

    { setup,
      fun () -> ets:new (?MODULE, [ public, set ]) end,
      fun (Tab) -> ets:delete (Tab) end,
      fun (Tab) -> { timeout, 60, F (Tab) } end
    }.

call_test_ () ->
  F = 
    fun (Tab) ->
      fun () ->
        { ok, Pid } = gen_cron:start_link (gen_cron_test,
                                           infinity,
                                           [ Tab ],
                                           [ ]),
  
        MRef = erlang:monitor (process, Pid),
  
        flass = gen_server:call (Pid, turg),
        flass = gen_server:call (Pid, turg),
  
        exit (Pid, shutdown),
  
        receive
          { 'DOWN', MRef, _, _, Info } -> ?assert (Info =:= shutdown)
        end,
  
        ?assert (ets:lookup (Tab, count) =:= [{ count, 0 }]),
        ?assert (ets:lookup (Tab, force) =:= [{ force, 0 }]),
        ?assert (ets:lookup (Tab, tick_monitor) =:= [{ tick_monitor, 0 }]),
        ?assert (ets:lookup (Tab, mega) =:= []),
        ?assert (ets:lookup (Tab, turg) =:= [{ turg, baitin }]),
        true
      end
    end,

    { setup,
      fun () -> ets:new (?MODULE, [ public, set ]) end,
      fun (Tab) -> ets:delete (Tab) end,
      fun (Tab) -> { timeout, 60, F (Tab) } end
    }.

info_test_ () ->
  F = 
    fun (Tab) ->
      fun () ->
        { ok, Pid } = gen_cron:start_link (gen_cron_test,
                                           infinity,
                                           [ Tab ],
                                           [ ]),
  
        MRef = erlang:monitor (process, Pid),
  
        Pid ! { mega, sweet },
        Pid ! { mega, sweet },
  
        exit (Pid, shutdown),
  
        receive
          { 'DOWN', MRef, _, _, Info } -> ?assert (Info =:= shutdown)
        end,
  
        ?assert (ets:lookup (Tab, count) =:= [{ count, 0 }]),
        ?assert (ets:lookup (Tab, force) =:= [{ force, 0 }]),
        ?assert (ets:lookup (Tab, tick_monitor) =:= [{ tick_monitor, 0 }]),
        ?assert (ets:lookup (Tab, mega) =:= [{ mega, sweet }]),
        ?assert (ets:lookup (Tab, turg) =:= []),
        true
      end
    end,

    { setup,
      fun () -> ets:new (?MODULE, [ public, set ]) end,
      fun (Tab) -> ets:delete (Tab) end,
      fun (Tab) -> { timeout, 60, F (Tab) } end
    }.

-endif.
