-module (mondriak).

-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour (gen_server).

%% API
-export ( [ start_link/0 ]).

%% Testing functions, testing was done in the shell for ease
-export ([ riak_kv_stats/1,
           riak_core_stats/1,
           rtq_stats/1,
           riak_repl_stats/1,
           riak_kv_v1/0,
           riak_kv_v2/0,
           riak_core_v1/0,
           riak_core_v2/0,
           riak_repl2_rtq_v1/0,
           riak_repl2_rtq_v2/0,
           riak_repl_stats_v1/0,
           riak_repl_stats_v2/0
         ]).

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
rtq_stats ([{percent_bytes_used,PctBytes}|Rest], Accum) ->
  rtq_stats (Rest,
             [ { gauge, rtq_percent_bytes_used, trunc(PctBytes*100) } | Accum ]
            );
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
% V2 changed the core stats pretty dramatically, so working around and only
% capturing those which seem useful
%
% There are bunch with the form
%   [riak,riak_core,
%    vnodeq,riak_kv_vnode, 102761833874829111436196589800363649819557756928],
% which I want to ignore
riak_core_stats ([{[riak,riak_core,vnodeq,_,_],_} | Rest ], Accum) ->
  riak_core_stats (Rest, Accum);

% a few which have special forms
% 
% these seem to have the form
% {[riak,riak_core,rings_reconciled],[{count,471},{one,0}]},
riak_core_stats ([{[riak,riak_core,K], V} | Rest ], Accum)
  when K =:= gossip_received;
       K =:= rings_reconciled ->
  riak_core_stats (Rest, [ riak_core_gauge (K, count, V) | Accum ]);
% and these the form
%  {[riak,riak_core,rejected_handoffs],[{value,0},{ms_since_reset,1744058941}]},
%  {[riak,riak_core,ring_creation_size],[{value,256}]},
riak_core_stats ([{[riak,riak_core,K], V} | Rest ],
                 Accum) when K =:= handoff_timeouts;
                             K =:= rejected_handoffs;
                             K =:= ring_creation_size ->
  riak_core_stats (Rest, [riak_core_gauge (K, value, V) | Accum ]);
riak_core_stats ([{[riak,riak_core,K], V} | Rest ],
                 Accum) when K =:= dropped_vnode_requests_total;
                             K =:= ignored_gossip_total ->
  riak_core_stats (Rest, [riak_core_counter (K, value, V) | Accum ]);

% and some which used to have the form
%   {converge_delay_min,0},
%   {converge_delay_max,0},
%   {converge_delay_mean,0},
%   {converge_delay_last,0},
% but now have the form
% {gauge,[riak,riak_core,converge_delay],
%         [{count,0},
%          {last,0},
%          {n,0},
%          {mean,0},
%          {min,0},
%          {max,0},
%          {median,0},
%          {50,0},
%          {75,0},
%          {90,0},
%          {95,0},
%          {99,0},
%          {999,0}]},
riak_core_stats ([{[riak,riak_core,K],V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ riak_core_gauge (K, min, V),
                           riak_core_gauge (K, max, V),
                           riak_core_gauge (K, mean, V),
                           riak_core_gauge (K, last, V) | Accum ]);
riak_core_stats ([{[riak,riak_core,vnodes_running,riak_pipe_vnode], V} | Rest],
                 Accum) ->
  riak_core_stats (Rest, [ riak_core_counter (riak_pipe_vnodes_running, value, V)
                           | Accum ]);
riak_core_stats ([{[riak,riak_core,vnodeq,riak_pipe_vnode], V} | Rest],
                 Accum) ->
  riak_core_stats (Rest, [ riak_core_gauge (riak_pipe_vnodeq_total, total, V),
                           riak_core_gauge (riak_pipe_vnodeq_total, max, V),
                           riak_core_gauge (riak_pipe_vnodeq_total, mean, V),
                           riak_core_gauge (riak_pipe_vnodeq_total, median, V),
                           riak_core_gauge (riak_pipe_vnodeq_total, min, V)
                           | Accum ]);

riak_core_stats ([{[riak,riak_core,vnodes_running,riak_kv_vnode], V} | Rest],
                 Accum) ->
  riak_core_stats (Rest, [ riak_core_counter (riak_kv_vnodes_running, value, V)
                           | Accum ]);
riak_core_stats ([{[riak,riak_core,vnodeq,riak_kv_vnode], V} | Rest],
                 Accum) ->
  riak_core_stats (Rest, [ riak_core_gauge (riak_kv_vnodeq_total, total, V),
                           riak_core_gauge (riak_kv_vnodeq_total, max, V),
                           riak_core_gauge (riak_kv_vnodeq_total, mean, V),
                           riak_core_gauge (riak_kv_vnodeq_total, median, V),
                           riak_core_gauge (riak_kv_vnodeq_total, min, V)
                           | Accum ]);

riak_core_stats ([{K,V} | Rest ], Accum) ->
  riak_core_stats (Rest, [ {gauge, K, V} | Accum ]).

riak_core_counter (K, SK, PL) -> riak_core_sub (counter, K, SK, PL).
riak_core_gauge (K, SK, PL) -> riak_core_sub (gauge, K, SK, PL).

riak_core_sub (T, K, SK, PL) ->
  FinalK =
    case SK of
      K1 when K1 =:= count; K1 =:= value -> K;
      _ -> list_to_atom (atom_to_list (K) ++ "_" ++ atom_to_list (SK))
    end,

  FinalV =
    case proplists:get_value (SK, PL, 0) of
      F when is_float (F) -> trunc (F);
      V -> V
    end,

  { T, FinalK, FinalV }.

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
%-ifdef(EUNIT).

% output from riak_kv_status:statistics() in Riak V1
riak_kv_v1 () ->
  [{riak_kv_stat_ts,1432755607},
   {vnode_gets,122536},
   {vnode_gets_total,14790262591},
   {vnode_puts,85885},
   {vnode_puts_total,11030232132},
   {vnode_index_refreshes,0},
   {vnode_index_refreshes_total,0},
   {vnode_index_reads,0},
   {vnode_index_reads_total,0},
   {vnode_index_writes,0},
   {vnode_index_writes_total,0},
   {vnode_index_writes_postings,0},
   {vnode_index_writes_postings_total,0},
   {vnode_index_deletes,0},
   {vnode_index_deletes_total,0},
   {vnode_index_deletes_postings,0},
   {vnode_index_deletes_postings_total,0},
   {node_gets,35071},
   {node_gets_total,4698955005},
   {node_get_fsm_siblings_mean,1},
   {node_get_fsm_siblings_median,1},
   {node_get_fsm_siblings_95,2},
   {node_get_fsm_siblings_99,3},
   {node_get_fsm_siblings_100,43},
   {node_get_fsm_objsize_mean,1132},
   {node_get_fsm_objsize_median,1197},
   {node_get_fsm_objsize_95,1891},
   {node_get_fsm_objsize_99,3272},
   {node_get_fsm_objsize_100,62333},
   {node_get_fsm_time_mean,666},
   {node_get_fsm_time_median,646},
   {node_get_fsm_time_95,935},
   {node_get_fsm_time_99,1243},
   {node_get_fsm_time_100,14454},
   {node_puts,28528},
   {node_puts_total,3593619847},
   {node_put_fsm_time_mean,1762},
   {node_put_fsm_time_median,1150},
   {node_put_fsm_time_95,2065},
   {node_put_fsm_time_99,5710},
   {node_put_fsm_time_100,297395},
   {read_repairs,366},
   {read_repairs_total,114524884},
   {coord_redirs_total,3309469635},
   {executing_mappers,0},
   {precommit_fail,0},
   {postcommit_fail,0},
   {index_fsm_create,0},
   {index_fsm_create_error,0},
   {index_fsm_active,0},
   {list_fsm_create,0},
   {list_fsm_create_error,0},
   {list_fsm_active,0},
   {pbc_active,38},
   {pbc_connects,123},
   {pbc_connects_total,33623565},
   {node_get_fsm_active,89},
   {node_get_fsm_active_60s,34913},
   {node_get_fsm_in_rate,562},
   {node_get_fsm_out_rate,557},
   {node_get_fsm_rejected,0},
   {node_get_fsm_rejected_60s,0},
   {node_get_fsm_rejected_total,0},
   {node_put_fsm_active,1},
   {node_put_fsm_active_60s,56761},
   {node_put_fsm_in_rate,939},
   {node_put_fsm_out_rate,939},
   {node_put_fsm_rejected,0},
   {node_put_fsm_rejected_60s,0},
   {node_put_fsm_rejected_total,24564830},
   {read_repairs_primary_outofdate_one,601},
   {read_repairs_primary_outofdate_count,182729402},
   {read_repairs_primary_notfound_one,39},
   {read_repairs_primary_notfound_count,17694349},
   {read_repairs_fallback_outofdate_one,14},
   {read_repairs_fallback_outofdate_count,767169},
   {read_repairs_fallback_notfound_one,2},
   {read_repairs_fallback_notfound_count,1814682},
   {leveldb_read_block_error,undefined},
   {riak_pipe_stat_ts,1432755607},
   {pipeline_active,0},
   {pipeline_create_count,0},
   {pipeline_create_one,0},
   {pipeline_create_error_count,0},
   {pipeline_create_error_one,0},
   {cpu_nprocs,616},
   {cpu_avg1,2376},
   {cpu_avg5,2281},
   {cpu_avg15,2248},
   {mem_total,67683487744},
   {mem_allocated,65175908352},
   {disk,[{"/",19194652,11},
          {"/var",633725696,40},
          {"/boot",472832,7},
          {"/dev/shm",33048576,0}]},
   {nodename,'riak@10.5.33.23'},
   {connected_nodes,['riak@10.5.8.36','riak@10.5.7.15','riak@10.5.39.30',
                     'riak@10.5.6.22','riak@10.5.33.28','riak@10.5.19.48',
                     'riak@10.5.11.39','riak@10.5.12.46','riak@10.5.12.14',
                     'riak@10.5.19.22','riak@10.5.18.23','riak@10.5.33.24',
                     'riak@10.5.33.38','riak@10.5.33.39','riak@10.5.33.41',
                     'riak@10.5.38.14','riak@10.5.38.18','riak@10.5.38.24',
                     'riak@10.5.38.29','riak@10.5.38.36','riak@10.5.38.37',
                     'riak@10.5.38.38','riak@10.5.38.41','riak@10.5.40.42',
                     'riak@10.5.36.16','riak@10.5.38.17','riak@10.5.38.15',
                     'riak@10.5.40.16','riak@10.5.35.39','riak@10.5.38.20',
                     'riak@10.5.44.42','riak@10.5.44.24','riak@10.5.43.16',
                     'riak@10.5.38.32','riak@10.5.35.29','riak@10.5.35.16',
                     'riak@10.5.40.43','riak@10.5.43.42','riak@10.5.41.16',
                     'riak@10.5.34.40','riak@10.5.42.16','riak@10.5.42.18',
                     'riak@10.5.38.34','riak@10.5.42.42','riak@10.5.38.28',
                     'riak@10.5.44.22','riak@10.5.41.39','riak@10.5.34.23',
                     'riak@10.5.44.43','riak@10.5.34.21','riak@10.5.41.38',
                     'riak@10.5.38.31','riak@10.5.35.40','riak@10.5.44.19',
                     'riak@10.5.38.25','riak@10.5.41.42','riak@10.5.35.38',
                     'riak@10.5.35.43','riak@10.5.38.27','riak@10.5.36.24',
                     'riak@10.5.42.41','riak@10.5.38.23','riak@10.5.35.24',
                     'riak@10.5.35.23','riak@10.5.36.43','riak@10.5.38.26',
                     'riak@10.5.38.16','riak@10.5.41.43','riak@10.5.38.39',
                     'riak@10.5.35.21','riak@10.5.38.19','riak@10.5.35.22',
                     'riak@10.5.38.30','riak@10.5.34.43','riak@10.5.38.21',
                     'riak@10.5.36.40','riak@10.5.35.42','riak@10.5.40.39',
                     'riak@10.5.34.42','riak@10.5.34.29','riak@10.5.38.35',
                     'riak@10.5.43.43','riak@10.5.38.40','riak@10.5.38.22',
                     'riak@10.5.38.12','riak@10.5.38.33','riak@10.5.34.16',
                     'riak@10.5.34.22']},
   {sys_driver_version,<<"2.0">>},
   {sys_global_heaps_size,0},
   {sys_heap_type,private},
   {sys_logical_processors,24},
   {sys_otp_release,<<"R15B01">>},
   {sys_process_count,4036},
   {sys_smp_support,true},
   {sys_system_version,<<"Erlang R15B01 (erts-5.9.1) [source] [64-bit] [smp:24:24] [async-threads:256] [kernel-poll:true]">>},
   {sys_system_architecture,<<"x86_64-unknown-linux-gnu">>},
   {sys_threads_enabled,true},
   {sys_thread_pool_size,256},
   {sys_wordsize,8},
   {ring_members,['riak@10.5.33.23','riak@10.5.33.24','riak@10.5.33.28',
                  'riak@10.5.33.38','riak@10.5.33.39','riak@10.5.33.41',
                  'riak@10.5.34.16','riak@10.5.34.21','riak@10.5.34.22',
                  'riak@10.5.34.23','riak@10.5.34.29','riak@10.5.34.40',
                  'riak@10.5.34.42','riak@10.5.34.43','riak@10.5.35.16',
                  'riak@10.5.35.21','riak@10.5.35.22','riak@10.5.35.23',
                  'riak@10.5.35.24','riak@10.5.35.29','riak@10.5.35.38',
                  'riak@10.5.35.39','riak@10.5.35.40','riak@10.5.35.42',
                  'riak@10.5.35.43','riak@10.5.36.16','riak@10.5.36.23',
                  'riak@10.5.36.24','riak@10.5.36.40','riak@10.5.36.43',
                  'riak@10.5.38.12','riak@10.5.38.14','riak@10.5.38.15',
                  'riak@10.5.38.16','riak@10.5.38.17','riak@10.5.38.18',
                  'riak@10.5.38.19','riak@10.5.38.20','riak@10.5.38.21',
                  'riak@10.5.38.22','riak@10.5.38.23','riak@10.5.38.24',
                  'riak@10.5.38.25','riak@10.5.38.26','riak@10.5.38.27',
                  'riak@10.5.38.28','riak@10.5.38.29','riak@10.5.38.30',
                  'riak@10.5.38.31','riak@10.5.38.32','riak@10.5.38.33',
                  'riak@10.5.38.34','riak@10.5.38.35','riak@10.5.38.36',
                  'riak@10.5.38.37','riak@10.5.38.38','riak@10.5.38.39',
                  'riak@10.5.38.40','riak@10.5.38.41','riak@10.5.40.16',
                  'riak@10.5.40.39','riak@10.5.40.42','riak@10.5.40.43',
                  'riak@10.5.41.16','riak@10.5.41.38','riak@10.5.41.39',
                  'riak@10.5.41.42','riak@10.5.41.43','riak@10.5.42.16',
                  'riak@10.5.42.18','riak@10.5.42.41','riak@10.5.42.42',
                  'riak@10.5.43.16','riak@10.5.43.42','riak@10.5.43.43',
                  'riak@10.5.44.19','riak@10.5.44.22','riak@10.5.44.24',
                  'riak@10.5.44.42','riak@10.5.44.43']},
   {ring_num_partitions,1024},
   {ring_ownership,<<"[{'riak@10.5.34.40',15},\n {'riak@10.5.38.30',13},\n {'riak@10.5.38.40',13},\n {'riak@10.5.38.20',13},\n {'riak@10.5.36.40',12},\n {'riak@10.5.35.40',12},\n {'riak@10.5.35.21',14},\n {'riak@10.5.33.41',14},\n {'riak@10.5.34.21',15},\n {'riak@10.5.38.41',13},\n {'riak@10.5.38.21',13},\n {'riak@10.5.38.31',13},\n {'riak@10.5.42.41',12},\n {'riak@10.5.34.42',13},\n {'riak@10.5.34.22',14},\n {'riak@10.5.40.42',13},\n {'riak@10.5.38.32',14},\n {'riak@10.5.44.22',14},\n {'riak@10.5.38.22',13},\n {'riak@10.5.44.42',13},\n {'riak@10.5.38.12',12},\n {'riak@10.5.43.42',12},\n {'riak@10.5.35.22',14},\n {'riak@10.5.35.42',12},\n {'riak@10.5.42.42',12},\n {'riak@10.5.41.42',12},\n {'riak@10.5.33.23',13},\n {'riak@10.5.34.23',14},\n {'riak@10.5.40.43',13},\n {'riak@10.5.44.43',13},\n{'riak@10.5.38.23',14},\n {'riak@10.5.34.43',15},\n {'riak@10.5.43.43',13},\n {'riak@10.5.36.43',12},\n {'riak@10.5.36.23',12},\n {'riak@10.5.35.43',12},\n {'riak@10.5.35.23',12},\n {'riak@10.5.38.33',12},\n {'riak@10.5.41.43',12},\n {'riak@10.5.33.24',13},\n {'riak@10.5.44.24',13},\n {'riak@10.5.38.24',13},\n {'riak@10.5.38.14',13},\n {'riak@10.5.36.24',13},\n {'riak@10.5.35.24',12},\n {'riak@10.5.38.34',12},\n {'riak@10.5.38.15',13},\n {'riak@10.5.38.25',12},\n {'riak@10.5.38.35',12},\n {'riak@10.5.35.16',13},\n {'riak@10.5.34.16',14},\n {'riak@10.5.41.16',13},\n {'riak@10.5.40.16',13},\n {'riak@10.5.38.16',14},\n {'riak@10.5.43.16',12},\n {'riak@10.5.36.16',12},\n {'riak@10.5.38.36',12},\n {'riak@10.5.38.26',12},\n {'riak@10.5.42.16',12},\n {'riak@10.5.38.17',13},\n {'riak@10.5.38.27',12},\n {'riak@10.5.38.37',12},\n {'riak@10.5.33.38',13},\n {'riak@10.5.41.38',13},\n {'riak@10.5.38.28',13},\n {'riak@10.5.33.28',12},\n {'riak@10.5.38.18',12},\n {'riak@10.5.42.18',12},\n {'riak@10.5.35.38',12},\n {'riak@10.5.38.38',12},\n {'riak@10.5.34.29',14},\n {'riak@10.5.33.39',14},\n {'riak@10.5.40.39',13},\n {'riak@10.5.38.29',14},\n {'riak@10.5.38.39',13},\n {'riak@10.5.38.19',12},\n {'riak@10.5.44.19',12},\n {'riak@10.5.35.39',12},\n {'riak@10.5.41.39',12},\n {'riak@10.5.35.29',12}]">>},
    {ring_creation_size,1024},
    {storage_backend,riak_kv_multi_backend},
    {mondriak_version,<<"0.5.0">>},
    {mondemand_version,<<"5.0.0">>},
    {lwes_version,<<"3.0.1">>},
    {erlydtl_version,<<"0.7.0">>},
    {riak_control_version,<<"1.4.4-0-g9a74e57">>},
    {cluster_info_version,<<"1.2.4">>},
    {riak_jmx_version,<<"1.4.4-0-g11e104e">>},
    {riak_snmp_version,<<"1.2.3">>},
    {riak_repl_version,<<"1.4.8">>},
    {ranch_version,<<"0.4.0-p1">>},
    {riak_search_version,<<"1.4.8-0-gbe6e4ed">>},
    {merge_index_version,<<"1.3.2-0-gcb38ee7">>},
    {riak_kv_version,<<"1.4.8-0-g7545390">>},
    {sidejob_version,<<"0.2.0">>},
    {riak_api_version,<<"1.4.4-0-g395e6fd">>},
    {riak_pipe_version,<<"1.4.4-0-g7f390f3">>},
    {riak_core_version,<<"1.4.4">>},
    {bitcask_version,<<"1.6.6-0-g230b6d6">>},
    {basho_stats_version,<<"1.0.3">>},
    {webmachine_version,<<"1.10.4-0-gfcff795">>},
    {mochiweb_version,<<"1.5.1p6">>},
    {inets_version,<<"5.9">>},
    {erlang_js_version,<<"1.2.2">>},
    {mnesia_version,<<"4.7">>},
    {snmp_version,<<"4.22">>},
    {runtime_tools_version,<<"1.8.8">>},
    {os_mon_version,<<"2.2.9">>},
    {riak_sysmon_version,<<"1.1.3">>},
    {ssl_version,<<"5.0.1">>},
    {public_key_version,<<"0.15">>},
    {crypto_version,<<"2.1">>},
    {sasl_version,<<"2.2.1">>},
    {lager_version,<<"2.0.1">>},
    {syslog_version,<<"1.0.2">>},
    {goldrush_version,<<"0.1.5">>},
    {compiler_version,<<"4.8.1">>},
    {syntax_tools_version,<<"1.6.8">>},
    {stdlib_version,<<"1.18.1">>},
    {kernel_version,<<"2.15.1">>},
    {memory_total,22085123280},
    {memory_processes,141961961},
    {memory_processes_used,141827708},
    {memory_system,21943161319},
    {memory_atom,1197257},
    {memory_atom_used,1166520},
    {memory_binary,5400472},
    {memory_code,17735927},
    {memory_ets,124871816}].

% output from riak_kv_status:statistics() in Riak V2
riak_kv_v2 () ->
  [{connected_nodes,['riak@10.2.0.42','riak@10.2.2.27','riak@10.2.3.31',
                     'riak@10.2.4.22','riak@10.2.6.44','riak@10.2.7.22',
                     'riak@10.2.7.23','riak@10.2.21.29','riak@10.2.22.42',
                     'riak@10.2.25.27','riak@10.2.25.33','riak@10.2.25.36',
                     'riak@10.2.25.42','riak@10.2.25.44','riak@10.2.26.42',
                     'riak@10.2.36.30','riak@10.2.37.45']},
    {consistent_get_objsize_100,0},
    {consistent_get_objsize_95,0},
    {consistent_get_objsize_99,0},
    {consistent_get_objsize_mean,0},
    {consistent_get_objsize_median,0},
    {consistent_get_time_100,0},
    {consistent_get_time_95,0},
    {consistent_get_time_99,0},
    {consistent_get_time_mean,0},
    {consistent_get_time_median,0},
    {consistent_gets,0},
    {consistent_gets_total,0},
    {consistent_put_objsize_100,0},
    {consistent_put_objsize_95,0},
    {consistent_put_objsize_99,0},
    {consistent_put_objsize_mean,0},
    {consistent_put_objsize_median,0},
    {consistent_put_time_100,0},
    {consistent_put_time_95,0},
    {consistent_put_time_99,0},
    {consistent_put_time_mean,0},
    {consistent_put_time_median,0},
    {consistent_puts,0},
    {consistent_puts_total,0},
    {converge_delay_last,4359286345},
    {converge_delay_max,0},
    {converge_delay_mean,0},
    {converge_delay_min,0},
    {coord_redirs_total,0},
    {counter_actor_counts_100,0},
    {counter_actor_counts_95,0},
    {counter_actor_counts_99,0},
    {counter_actor_counts_mean,0},
    {counter_actor_counts_median,0},
    {cpu_avg1,44},
    {cpu_avg15,443},
    {cpu_avg5,353},
    {cpu_nprocs,541},
    {dropped_vnode_requests_total,0},
    {executing_mappers,0},
    {gossip_received,0},
    {handoff_timeouts,0},
    {ignored_gossip_total,0},
    {index_fsm_active,0},
    {index_fsm_create,0},
    {index_fsm_create_error,0},
    {late_put_fsm_coordinator_ack,0},
    {leveldb_read_block_error,0},
    {list_fsm_active,0},
    {list_fsm_create,0},
    {list_fsm_create_error,0},
    {list_fsm_create_error_total,0},
    {list_fsm_create_total,0},
    {map_actor_counts_100,0},
    {map_actor_counts_95,0},
    {map_actor_counts_99,0},
    {map_actor_counts_mean,0},
    {map_actor_counts_median,0},
    {mem_allocated,13023612928},
    {mem_total,33791447040},
    {memory_atom,834473},
    {memory_atom_used,811286},
    {memory_binary,26055200},
    {memory_code,21628420},
    {memory_ets,13228112},
    {memory_processes,122727248},
    {memory_processes_used,122723632},
    {memory_system,105273424},
    {memory_total,228000672},
    {node_get_fsm_active,0},
    {node_get_fsm_active_60s,0},
    {node_get_fsm_counter_objsize_100,0},
    {node_get_fsm_counter_objsize_95,0},
    {node_get_fsm_counter_objsize_99,0},
    {node_get_fsm_counter_objsize_mean,0},
    {node_get_fsm_counter_objsize_median,0},
    {node_get_fsm_counter_siblings_100,0},
    {node_get_fsm_counter_siblings_95,0},
    {node_get_fsm_counter_siblings_99,0},
    {node_get_fsm_counter_siblings_mean,0},
    {node_get_fsm_counter_siblings_median,0},
    {node_get_fsm_counter_time_100,0},
    {node_get_fsm_counter_time_95,0},
    {node_get_fsm_counter_time_99,0},
    {node_get_fsm_counter_time_mean,0},
    {node_get_fsm_counter_time_median,0},
    {node_get_fsm_errors,0},
    {node_get_fsm_errors_total,0},
    {node_get_fsm_in_rate,0},
    {node_get_fsm_map_objsize_100,0},
    {node_get_fsm_map_objsize_95,0},
    {node_get_fsm_map_objsize_99,0},
    {node_get_fsm_map_objsize_mean,0},
    {node_get_fsm_map_objsize_median,0},
    {node_get_fsm_map_siblings_100,0},
    {node_get_fsm_map_siblings_95,0},
    {node_get_fsm_map_siblings_99,0},
    {node_get_fsm_map_siblings_mean,0},
    {node_get_fsm_map_siblings_median,0},
    {node_get_fsm_map_time_100,0},
    {node_get_fsm_map_time_95,0},
    {node_get_fsm_map_time_99,0},
    {node_get_fsm_map_time_mean,0},
    {node_get_fsm_map_time_median,0},
    {node_get_fsm_objsize_100,0},
    {node_get_fsm_objsize_95,0},
    {node_get_fsm_objsize_99,0},
    {node_get_fsm_objsize_mean,0},
    {node_get_fsm_objsize_median,0},
    {node_get_fsm_out_rate,0},
    {node_get_fsm_rejected,0},
    {node_get_fsm_rejected_60s,0},
    {node_get_fsm_rejected_total,0},
    {node_get_fsm_set_objsize_100,0},
    {node_get_fsm_set_objsize_95,0},
    {node_get_fsm_set_objsize_99,0},
    {node_get_fsm_set_objsize_mean,0},
    {node_get_fsm_set_objsize_median,0},
    {node_get_fsm_set_siblings_100,0},
    {node_get_fsm_set_siblings_95,0},
    {node_get_fsm_set_siblings_99,0},
    {node_get_fsm_set_siblings_mean,0},
    {node_get_fsm_set_siblings_median,0},
    {node_get_fsm_set_time_100,0},
    {node_get_fsm_set_time_95,0},
    {node_get_fsm_set_time_99,0},
    {node_get_fsm_set_time_mean,0},
    {node_get_fsm_set_time_median,0},
    {node_get_fsm_siblings_100,0},
    {node_get_fsm_siblings_95,0},
    {node_get_fsm_siblings_99,0},
    {node_get_fsm_siblings_mean,0},
    {node_get_fsm_siblings_median,0},
    {node_get_fsm_time_100,0},
    {node_get_fsm_time_95,0},
    {node_get_fsm_time_99,0},
    {node_get_fsm_time_mean,0},
    {node_get_fsm_time_median,0},
    {node_gets,0},
    {node_gets_counter,0},
    {node_gets_counter_total,0},
    {node_gets_map,0},
    {node_gets_map_total,0},
    {node_gets_set,0},
    {node_gets_set_total,0},
    {node_gets_total,3},
    {node_put_fsm_active,0},
    {node_put_fsm_active_60s,1},
    {node_put_fsm_counter_time_100,0},
    {node_put_fsm_counter_time_95,0},
    {node_put_fsm_counter_time_99,0},
    {node_put_fsm_counter_time_mean,0},
    {node_put_fsm_counter_time_median,0},
    {node_put_fsm_in_rate,0},
    {node_put_fsm_map_time_100,0},
    {node_put_fsm_map_time_95,0},
    {node_put_fsm_map_time_99,0},
    {node_put_fsm_map_time_mean,0},
    {node_put_fsm_map_time_median,0},
    {node_put_fsm_out_rate,0},
    {node_put_fsm_rejected,0},
    {node_put_fsm_rejected_60s,0},
    {node_put_fsm_rejected_total,0},
    {node_put_fsm_set_time_100,0},
    {node_put_fsm_set_time_95,0},
    {node_put_fsm_set_time_99,0},
    {node_put_fsm_set_time_mean,0},
    {node_put_fsm_set_time_median,0},
    {node_put_fsm_time_100,838},
    {node_put_fsm_time_95,838},
    {node_put_fsm_time_99,838},
    {node_put_fsm_time_mean,838},
    {node_put_fsm_time_median,838},
    {node_puts,1},
    {node_puts_counter,0},
    {node_puts_counter_total,0},
    {node_puts_map,0},
    {node_puts_map_total,0},
    {node_puts_set,0},
    {node_puts_set_total,0},
    {node_puts_total,4734568},
    {nodename,'riak@10.2.0.26'},
    {object_counter_merge,0},
    {object_counter_merge_time_100,0},
    {object_counter_merge_time_95,0},
    {object_counter_merge_time_99,0},
    {object_counter_merge_time_mean,0},
    {object_counter_merge_time_median,0},
    {object_counter_merge_total,0},
    {object_map_merge,0},
    {object_map_merge_time_100,0},
    {object_map_merge_time_95,0},
    {object_map_merge_time_99,0},
    {object_map_merge_time_mean,0},
    {object_map_merge_time_median,0},
    {object_map_merge_total,0},
    {object_merge,3},
    {object_merge_time_100,52},
    {object_merge_time_95,52},
    {object_merge_time_99,52},
    {object_merge_time_mean,37},
    {object_merge_time_median,31},
    {object_merge_total,347443},
    {object_set_merge,0},
    {object_set_merge_time_100,0},
    {object_set_merge_time_95,0},
    {object_set_merge_time_99,0},
    {object_set_merge_time_mean,0},
    {object_set_merge_time_median,0},
    {object_set_merge_total,0},
    {pbc_active,0},
    {pbc_connects,12},
    {pbc_connects_total,347093},
    {pipeline_active,0},
    {pipeline_create_count,0},
    {pipeline_create_error_count,0},
    {pipeline_create_error_one,0},
    {pipeline_create_one,0},
    {postcommit_fail,0},
    {precommit_fail,0},
    {read_repairs,0},
    {read_repairs_counter,0},
    {read_repairs_counter_total,0},
    {read_repairs_fallback_notfound_count,undefined},
    {read_repairs_fallback_notfound_one,undefined},
    {read_repairs_fallback_outofdate_count,undefined},
    {read_repairs_fallback_outofdate_one,undefined},
    {read_repairs_map,0},
    {read_repairs_map_total,0},
    {read_repairs_primary_notfound_count,undefined},
    {read_repairs_primary_notfound_one,undefined},
    {read_repairs_primary_outofdate_count,undefined},
    {read_repairs_primary_outofdate_one,undefined},
    {read_repairs_set,0},
    {read_repairs_set_total,0},
    {read_repairs_total,0},
    {rebalance_delay_last,0},
    {rebalance_delay_max,0},
    {rebalance_delay_mean,0},
    {rebalance_delay_min,0},
    {rejected_handoffs,0},
    {riak_kv_vnodeq_max,0},
    {riak_kv_vnodeq_mean,0.0},
    {riak_kv_vnodeq_median,0},
    {riak_kv_vnodeq_min,0},
    {riak_kv_vnodeq_total,0},
    {riak_kv_vnodes_running,15},
    {riak_pipe_vnodeq_max,0},
    {riak_pipe_vnodeq_mean,0.0},
    {riak_pipe_vnodeq_median,0},
    {riak_pipe_vnodeq_min,0},
    {riak_pipe_vnodeq_total,0},
    {riak_pipe_vnodes_running,15},
    {ring_creation_size,256},
    {ring_members,['riak@10.2.0.26','riak@10.2.0.42','riak@10.2.2.27',
                   'riak@10.2.21.29','riak@10.2.22.42','riak@10.2.25.27',
                   'riak@10.2.25.33','riak@10.2.25.36','riak@10.2.25.42',
                   'riak@10.2.25.44','riak@10.2.26.42','riak@10.2.3.31',
                   'riak@10.2.36.30','riak@10.2.37.45','riak@10.2.4.22',
                   'riak@10.2.6.44','riak@10.2.7.22','riak@10.2.7.23']},
    {ring_num_partitions,256},
    {ring_ownership,<<"[{'riak@10.2.36.30',14},\n {'riak@10.2.3.31',14},\n {'riak@10.2.7.22',14},\n {'riak@10.2.4.22',14},\n {'riak@10.2.26.42',14},\n {'riak@10.2.25.42',14},\n {'riak@10.2.22.42',14},\n {'riak@10.2.0.42',15},\n {'riak@10.2.7.23',14},\n {'riak@10.2.25.33',14},\n {'riak@10.2.6.44',14},\n {'riak@10.2.25.44',14},\n {'riak@10.2.37.45',14},\n {'riak@10.2.25.36',14},\n {'riak@10.2.0.26',15},\n {'riak@10.2.25.27',14},\n {'riak@10.2.2.27',15},\n {'riak@10.2.21.29',15}]">>},
    {rings_reconciled,0},
    {rings_reconciled_total,471},
    {set_actor_counts_100,0},
    {set_actor_counts_95,0},
    {set_actor_counts_99,0},
    {set_actor_counts_mean,0},
    {set_actor_counts_median,0},
    {skipped_read_repairs,0},
    {skipped_read_repairs_total,0},
    {storage_backend,riak_kv_eleveldb_backend},
    {sys_driver_version,<<"2.2">>},
    {sys_global_heaps_size,deprecated},
    {sys_heap_type,private},
    {sys_logical_processors,24},
    {sys_monitor_count,360},
    {sys_otp_release,<<"R16B02_basho8">>},
    {sys_port_count,64},
    {sys_process_count,2159},
    {sys_smp_support,true},
    {sys_system_architecture,<<"x86_64-unknown-linux-gnu">>},
    {sys_system_version,<<"Erlang R16B02_basho8 (erts-5.10.3) [source] [64-bit] [smp:24:24] [async-threads:64] [kernel-poll:true] [frame-pointer]">>},
    {sys_thread_pool_size,64},
    {sys_threads_enabled,true},
    {sys_wordsize,8},
    {vnode_counter_update,0},
    {vnode_counter_update_time_100,0},
    {vnode_counter_update_time_95,0},
    {vnode_counter_update_time_99,0},
    {vnode_counter_update_time_mean,0},
    {vnode_counter_update_time_median,0},
    {vnode_counter_update_total,0},
    {vnode_get_fsm_time_100,0},
    {vnode_get_fsm_time_95,0},
    {vnode_get_fsm_time_99,0},
    {vnode_get_fsm_time_mean,0},
    {vnode_get_fsm_time_median,0},
    {vnode_gets,0},
    {vnode_gets_total,5},
    {vnode_index_deletes,0},
    {vnode_index_deletes_postings,19},
    {vnode_index_deletes_postings_total,283981},
    {vnode_index_deletes_total,0},
    {vnode_index_reads,0},
    {vnode_index_reads_total,0},
    {vnode_index_refreshes,0},
    {vnode_index_refreshes_total,0},
    {vnode_index_writes,28},
    {vnode_index_writes_postings,23},
    {vnode_index_writes_postings_total,3152404},
    {vnode_index_writes_total,12359000},
    {vnode_map_update,0},
    {vnode_map_update_time_100,0},
    {vnode_map_update_time_95,0},
    {vnode_map_update_time_99,0},
    {vnode_map_update_time_mean,0},
    {vnode_map_update_time_median,0},
    {vnode_map_update_total,0},
    {vnode_put_fsm_time_100,537},
    {vnode_put_fsm_time_95,375},
    {vnode_put_fsm_time_99,491},
    {vnode_put_fsm_time_mean,207},
    {vnode_put_fsm_time_median,178},
    {vnode_puts,243},
    {vnode_puts_total,13389148},
    {vnode_set_update,0},
    {vnode_set_update_time_100,0},
    {vnode_set_update_time_95,0},
    {vnode_set_update_time_99,0},
    {vnode_set_update_time_mean,0},
    {vnode_set_update_time_median,0},
    {vnode_set_update_total,0},
    {write_once_merge,0},
    {write_once_put_objsize_100,0},
    {write_once_put_objsize_95,0},
    {write_once_put_objsize_99,0},
    {write_once_put_objsize_mean,0},
    {write_once_put_objsize_median,0},
    {write_once_put_time_100,0},
    {write_once_put_time_95,0},
    {write_once_put_time_99,0},
    {write_once_put_time_mean,0},
    {write_once_put_time_median,0},
    {write_once_puts,0},
    {write_once_puts_total,0},
    {disk,[{"/",20027260,8},
                   {"/dev/shm",16499728,0},
                   {"/boot",245679,33},
                   {"/var",206072512,3}]},
    {mondriak_version,<<"0.5.0">>},
    {mondemand_version,<<"5.0.0">>},
    {lwes_version,<<"3.0.1">>},
    {riak_auth_mods_version,<<"2.0.1-0-g31b8b30">>},
    {erlydtl_version,<<"0.7.0">>},
    {riak_control_version,<<"2.1.1-0-g5898c40">>},
    {cluster_info_version,<<"2.0.2-0-ge231144">>},
    {riak_jmx_version,<<"2.0.2-0-gb799946">>},
    {riak_snmp_version,<<"2.0.1-0-g3200c40">>},
    {riak_repl_version,<<"2.0.3-9-gdf36463">>},
    {ranch_version,<<"0.4.0-p1">>},
    {ebloom_version,<<"2.0.0">>},
    {yokozuna_version,<<"2.1.0-0-gcb41c27">>},
    {ibrowse_version,<<"4.0.2">>},
    {riak_search_version,<<"2.0.2-0-g8fe4a8c">>},
    {merge_index_version,<<"2.0.0-0-gb701dde">>},
    {riak_kv_version,<<"2.1.0-0-g6e88b24">>},
    {riak_api_version,<<"2.1.1-2-g94a9485">>},
    {riak_pb_version,<<"2.1.0.2-0-g620bc70">>},
    {protobuffs_version,<<"0.8.1p5-0-gf88fc3c">>},
    {riak_dt_version,<<"2.1.0-2-ga2986bc">>},
    {sidejob_version,<<"2.0.0-0-gc5aabba">>},
    {riak_pipe_version,<<"2.1.0-2-gc2d7d28">>},
    {riak_core_version,<<"2.1.1-0-g429c22d">>},
    {poolboy_version,<<"0.8.1p3-0-g8bb45fb">>},
    {pbkdf2_version,<<"2.0.0-0-g7076584">>},
    {eleveldb_version,<<"2.1.0-0-ga36dbd6">>},
    {clique_version,<<"0.2.6-0-g40072d2">>},
    {bitcask_version,<<"1.7.0">>},
    {basho_stats_version,<<"1.0.3">>},
    {webmachine_version,<<"1.10.8-0-g7677c24">>},
    {mochiweb_version,<<"2.9.0">>},
    {inets_version,<<"5.9.6">>},
    {xmerl_version,<<"1.3.4">>},
    {erlang_js_version,<<"1.3.0-0-g07467d8">>},
    {mnesia_version,<<"4.10">>},
    {snmp_version,<<"4.24.2">>},
    {runtime_tools_version,<<"1.8.12">>},
    {os_mon_version,<<"2.2.13">>},
    {riak_sysmon_version,<<"2.0.0">>},
    {exometer_core_version,<<"1.0.0-basho2-0-gb47a5d6">>},
    {ssl_version,<<"5.3.1">>},
    {public_key_version,<<"0.20">>},
    {crypto_version,<<"3.1">>},
    {asn1_version,<<"2.0.3">>},
    {sasl_version,<<"2.3.3">>},
    {lager_version,<<"2.0.3">>},
    {syslog_version,<<"1.0.2">>},
    {goldrush_version,<<"0.1.6">>},
    {compiler_version,<<"4.9.3">>},
    {syntax_tools_version,<<"1.6.11">>},
    {stdlib_version,<<"1.19.3">>},
    {kernel_version,<<"2.16.3">>}].

% output from riak_core_stat:get_stats() in Riak V1
riak_core_v1 () ->
  [{riak_core_stat_ts,1432756358},
    {ignored_gossip_total,0},
    {rings_reconciled_total,9634},
    {rings_reconciled,0},
    {gossip_received,6},
    {rejected_handoffs,624},
    {handoff_timeouts,0},
    {dropped_vnode_requests_total,0},
    {converge_delay_min,0},
    {converge_delay_max,0},
    {converge_delay_mean,0},
    {converge_delay_last,0},
    {rebalance_delay_min,0},
    {rebalance_delay_max,0},
    {rebalance_delay_mean,0},
    {rebalance_delay_last,0},
    {riak_kv_vnodes_running,13},
    {riak_kv_vnodeq_min,0},
    {riak_kv_vnodeq_median,0},
    {riak_kv_vnodeq_mean,0},
    {riak_kv_vnodeq_max,0},
    {riak_kv_vnodeq_total,0},
    {riak_pipe_vnodes_running,13},
    {riak_pipe_vnodeq_min,0},
    {riak_pipe_vnodeq_median,0},
    {riak_pipe_vnodeq_mean,0},
    {riak_pipe_vnodeq_max,0},
    {riak_pipe_vnodeq_total,0}].

% output from riak_core_stat:get_stats() in Riak V2
riak_core_v2 () ->
  [{[riak,riak_core,converge_delay],
    [{count,13},
     {last,4359286345},
     {n,0},
     {mean,0},
     {min,0},
     {max,0},
     {median,0},
     {50,0},
     {75,0},
     {90,0},
     {95,0},
     {99,0},
     {999,0}]},
   {[riak,riak_core,dropped_vnode_requests_total],
    [{value,0},{ms_since_reset,1744058941}]},
   {[riak,riak_core,gossip_received],[{count,174323},{one,0}]},
   {[riak,riak_core,handoff_timeouts],[{value,0},{ms_since_reset,1744058941}]},
   {[riak,riak_core,ignored_gossip_total],
    [{value,0},{ms_since_reset,1744058943}]},
   {[riak,riak_core,rebalance_delay],
    [{count,0},
     {last,0},
     {n,0},
     {mean,0},
     {min,0},
     {max,0},
     {median,0},
     {50,0},
     {75,0},
     {90,0},
     {95,0},
     {99,0},
     {999,0}]},
   {[riak,riak_core,rejected_handoffs],[{value,0},{ms_since_reset,1744058941}]},
   {[riak,riak_core,ring_creation_size],[{value,256}]},
   {[riak,riak_core,rings_reconciled],[{count,471},{one,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode],
    [{mean,0.0},{total,0},{min,0},{median,0},{max,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,0],[{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     102761833874829111436196589800363649819557756928],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     205523667749658222872393179600727299639115513856],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     308285501624487334308589769401090949458673270784],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     411047335499316445744786359201454599278231027712],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     513809169374145557180982949001818249097788784640],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     616571003248974668617179538802181898917346541568],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     719332837123803780053376128602545548736904298496],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     822094670998632891489572718402909198556462055424],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     924856504873462002925769308203272848376019812352],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     1027618338748291114361965898003636498195577569280],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     1130380172623120225798162487804000148015135326208],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     1233142006497949337234359077604363797834693083136],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     1335903840372778448670555667404727447654250840064],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_kv_vnode,
     1438665674247607560106752257205091097473808596992],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode],
    [{mean,0.0},{total,0},{min,0},{median,0},{max,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,0],[{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     102761833874829111436196589800363649819557756928],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     205523667749658222872393179600727299639115513856],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     308285501624487334308589769401090949458673270784],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     411047335499316445744786359201454599278231027712],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     513809169374145557180982949001818249097788784640],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     616571003248974668617179538802181898917346541568],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     719332837123803780053376128602545548736904298496],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     822094670998632891489572718402909198556462055424],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     924856504873462002925769308203272848376019812352],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     1027618338748291114361965898003636498195577569280],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     1130380172623120225798162487804000148015135326208],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     1233142006497949337234359077604363797834693083136],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     1335903840372778448670555667404727447654250840064],
    [{value,0}]},
   {[riak,riak_core,vnodeq,riak_pipe_vnode,
     1438665674247607560106752257205091097473808596992],
    [{value,0}]},
   {[riak,riak_core,vnodes_running,riak_kv_vnode],[{value,15}]},
   {[riak,riak_core,vnodes_running,riak_pipe_vnode],[{value,15}]}].

% Output from riak_repl2_rtq:status() in v1
riak_repl2_rtq_v1() ->
  [{bytes,720},
    {max_bytes,104857600},
    {consumers,[{"host1", [{pending,0},{unacked,0},{drops,0},{errs,2}]},
                {"host2", [{pending,0},{unacked,0},{drops,0},{errs,8}]},
                {"host3", [{pending,0},{unacked,0},{drops,0},{errs,3}]},
                {"host4", [{pending,0},{unacked,0},{drops,0},{errs,2}]}
               ]
    },
    {overload_drops,0}].

% Output from riak_repl2_rtq:status() in v2
riak_repl2_rtq_v2() ->
  [{percent_bytes_used,0.001},
   {bytes,712},
   {max_bytes,104857600},
   {consumers,[{"host1", [{pending,0},{unacked,0},{drops,0},{errs,0}]},
               {"host2", [{pending,0},{unacked,0},{drops,0},{errs,0}]},
               {"host3", [{pending,0},{unacked,0},{drops,0},{errs,0}]},
               {"host4", [{pending,0},{unacked,0},{drops,0},{errs,0}]}
              ]
   },
   {overload_drops,0}].

% Output form riak_repl_stats:get_stats() in v1
riak_repl_stats_v1() ->
  [{riak_repl_stat_ts,1432756752},
   {server_bytes_sent,199003918},
   {server_bytes_recv,0},
   {server_connects,0},
   {server_connect_errors,0},
   {server_fullsyncs,0},
   {client_bytes_sent,0},
   {client_bytes_recv,0},
   {client_connects,0},
   {client_connect_errors,0},
   {client_redirect,0},
   {objects_dropped_no_clients,0},
   {objects_dropped_no_leader,0},
   {objects_sent,14326747},
   {objects_forwarded,0},
   {elections_elected,0},
   {elections_leader_changed,0},
   {client_rx_kbps,[0,0,0,0,0,0,0,0]},
   {client_tx_kbps,[0,0,0,0,0,0,0,0]},
   {server_rx_kbps,[0,0,0,0,0,0,0,0]},
   {server_tx_kbps,[0,0,0,0,0,0,0,0]},
   {rt_source_errors,15},
   {rt_sink_errors,22},
   {rt_dirty,0}].

% Output form riak_repl_stats:get_stats() in v2
riak_repl_stats_v2() ->
  [{server_bytes_sent,6753577853},
   {server_bytes_recv,0},
   {server_connects,0},
   {server_connect_errors,0},
   {server_fullsyncs,0},
   {client_bytes_sent,110173948245},
   {client_bytes_recv,0},
   {client_connects,0},
   {client_connect_errors,0},
   {client_redirect,0},
   {objects_dropped_no_clients,0},
   {objects_dropped_no_leader,0},
   {objects_sent,191566},
   {objects_forwarded,0},
   {elections_elected,0},
   {elections_leader_changed,0},
   {client_rx_kbps,[0,0,0,0,0,0,0,0]},
   {client_tx_kbps,[0,1,5755,5999,0,0,0,6048]},
   {server_rx_kbps,[0,0,0,0,0,0,0,0]},
   {server_tx_kbps,[0,0,0,0,0,0,0,0]},
   {rt_source_errors,0},
   {rt_sink_errors,0},
   {rt_dirty,0}].

%-endif.
