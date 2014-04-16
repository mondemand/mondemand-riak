-module (mondriak).

-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour (gen_server).

%% API
-export ( [ start_link/0 ]).

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
  send_if_exists (riak_kv_status, statistics, fun riak_kv_stats/1, ProgId),
  send_if_exists (riak_core_stat, get_stats, fun riak_core_stats/1, ProgId),
  send_if_exists (riak_repl2_rtq, status, fun rtq_stats/1, ProgId),
  send_if_exists (riak_repl_stats, get_stats, fun riak_repl_stats/1, ProgId),
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

send_if_exists (Module, Function, ProcessFunc, ProgId) ->
  case code:which (Module) of
    non_existing -> ok;
    _ ->
      code:ensure_loaded (Module),
      case erlang:function_exported (Module, Function, 0) of
        false -> ok;
        true ->
          mondemand:send_stats (ProgId,
                                [],
                                ProcessFunc (Module:Function ()))
      end
  end.


riak_kv_stats (Stats) ->
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
               Stats).

rtq_stats (Stats) ->
  rtq_stats (Stats, []).

rtq_stats ([],Accum) ->
  Accum;
rtq_stats ([{bytes,Bytes}|Rest], Accum) ->
  rtq_stats (Rest, [ { gauge, rtq_bytes, Bytes } | Accum ]);
rtq_stats ([{max_bytes,Bytes}|Rest], Accum) ->
  rtq_stats (Rest, [ { gauge, rtq_max_bytes, Bytes } | Accum ]);
rtq_stats ([{consumers, Consumers }|Rest], Accum) ->
  rtq_stats (Rest, rtq_consumers (Consumers,[]) ++ Accum);
rtq_stats ([_|Rest], Accum) ->
  rtq_stats (Rest, Accum).

rtq_consumers ([], Accum) ->
  Accum;
rtq_consumers ([{K, V}|Rest],Accum) ->
  rtq_consumers (Rest, [ { gauge, atom_to_list(SK) ++ "-" ++ K, SV }
                         || { SK, SV }
                         <- V
                       ] ++ Accum).

riak_core_stats (Stats) ->
  riak_core_stats (Stats, []).

riak_core_stats ([], Accum) ->
  Accum;
riak_core_stats ([{riak_core_stat_ts,_} | Rest ], Accum) ->
  riak_core_stats (Rest, Accum);
riak_core_stats ([{K = ignored_gossip_total,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {counter, K, V} | Accum ]);
riak_core_stats ([{K = rings_reconciled_total,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {counter, K, V} | Accum ]);
riak_core_stats ([{K = dropped_vnode_requests_total,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {counter, K, V} | Accum ]);
riak_core_stats ([{K = riak_kv_vnodes_running,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {counter, K, V} | Accum ]);
riak_core_stats ([{K = riak_pipe_vnodes_running,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {counter, K, V} | Accum ]);
riak_core_stats ([{K,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {gauge, K, V} | Accum ]).

riak_repl_stats (Stats) ->
  lists:foldl (fun ({K,X}, A) when is_integer (X) ->
                     [ { counter, K, X } | A ] ;
                   (_, A) ->
                     A
               end,
               [],
               Stats).

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------
-ifdef(EUNIT).

-endif.
