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

-record (state, {interval}).
-define (DEFAULT_INTERVAL, 60000).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link ({local, ?MODULE}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
  Interval =
    case application:get_env (mondriak, emit_interval) of
      { ok, I } -> I;
      _ -> ?DEFAULT_INTERVAL
    end,
  { ok, #state{ interval = Interval }, Interval }.

handle_call (_Request, _From, State = #state { interval = Interval }) ->
  {reply, ok, State, Interval}.

handle_cast (_Request, State = #state { interval = Interval }) ->
  {noreply, State, Interval}.

handle_info (timeout, State = #state { interval = Interval }) ->
  mondemand:send_stats (riak,
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


%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------
-ifdef(EUNIT).

-endif.
