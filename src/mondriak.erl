-module (mondriak).

-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour (gen_server).

%% API
-export ( [ start_link/0,
            repl_stats/1 ]).

%% gen_server callbacks
-export ( [ init/1,
            handle_call/3,
            handle_cast/2,
            handle_info/2,
            terminate/2,
            code_change/3 ]).

-record (state, {interval, prog_id}).
-define (DEFAULT_INTERVAL, 60000).
-define (DEFAULT_PROG_ID, riak).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link ({local, ?MODULE}, ?MODULE, [], []).

program_id () ->
  case application:get_env (mondriak, prog_id) of
    {ok, I} -> I;
    _ -> ?DEFAULT_PROG_ID
  end.

emit_interval () ->
  case application:get_env (mondriak, emit_interval) of
    { ok, I } -> I;
    _ -> ?DEFAULT_INTERVAL
  end.

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
  Interval = emit_interval (),
  ProgId = program_id (),
  { ok, #state{ interval = Interval, prog_id = ProgId }, Interval }.

handle_call (_Request, _From, State = #state { interval = Interval }) ->
  {reply, ok, State, Interval}.

handle_cast (_Request, State = #state { interval = Interval }) ->
  {noreply, State, Interval}.

handle_info (timeout, State = #state { interval = Interval,
                                       prog_id = ProgId }) ->
  mondemand:send_stats (ProgId,
                        [],
                        lists:foldl (fun ( { K = vnode_gets_total, X }, A) ->
                                           [ { counter, K, X } | A ];
                                         ( { K = vnode_puts_total, X }, A) ->
                                           [ { counter, K, X } | A ];
                                         ( { K = node_gets_total, X }, A) ->
                                           [ { counter, K, X } | A ];
                                         ( { K = node_puts_total, X }, A) ->
                                           [ { counter, K, X } | A ];
                                         ( { K = read_repairs_total, X }, A) ->
                                           [ { counter, K, X } | A ];
                                         ( { K, X }, A) when is_integer (X) ->
                                           [ { gauge, K, X } | A ] ;
                                         ( { K, X }, A) when is_float (X) ->
                                           [ { gauge, K, round(X) } | A] ;
                                         (_, A) ->
                                           A
                                     end,
                                     [],
                                     riak_kv_status:statistics())),
  case code:which (riak_repl2_rtq) of
    non_existing -> ok;
    _ ->
      mondemand:send_stats (ProgId,
                            [],
                            repl_stats (riak_repl2_rtq:status()))
  end,
  case code:which (riak_repl_stats) of
    non_existing -> ok;
    _ ->
      mondemand:send_stats (ProgId,
                            [],
                            lists:foldl (fun ({K,X}, A) when is_integer (X) ->
                                               [ { counter, K, X } | A ] ;
                                             (_, A) ->
                                               A
                                         end,
                                         [],
                                         riak_repl_stats:get_stats()))
  end,
  {noreply, State, Interval};
handle_info (_Info, State = #state { interval = Interval }) ->
  {noreply, State, Interval}.

terminate (_Reason, _State) ->
  ok.

code_change (_OldVsn, State, _Extra) ->
  {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================
repl_stats (Stats) ->
  repl_stats (Stats, []).

repl_stats ([],Accum) ->
  Accum;
repl_stats ([{bytes,Bytes}|Rest], Accum) ->
  repl_stats (Rest, [ { gauge, rtq_bytes, Bytes } | Accum ]);
repl_stats ([{max_bytes,Bytes}|Rest], Accum) ->
  repl_stats (Rest, [ { gauge, rtq_max_bytes, Bytes } | Accum ]);
repl_stats ([{consumers, Consumers }|Rest], Accum) ->
  repl_stats (Rest, repl_consumers (Consumers,[]) ++ Accum);
repl_stats ([_|Rest], Accum) ->
  repl_stats (Rest, Accum).

repl_consumers ([], Accum) ->
  Accum;
repl_consumers ([{K, V}|Rest],Accum) ->
  repl_consumers (Rest, [ { gauge, atom_to_list(SK) ++ "-" ++ K, SV }
                          || { SK, SV }
                          <- V
                        ] ++ Accum).

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------
-ifdef(EUNIT).

-endif.
