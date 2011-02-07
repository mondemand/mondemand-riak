-module (mondriak_app).

-behaviour (application).

-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start/0]).

%% application callbacks
-export ([start/2, stop/1]).

%%====================================================================
%% API functions
%%====================================================================
start () ->
  [ ensure_started (App) || App <- [sasl, lwes, mondemand, mondriak]].

%%====================================================================
%% application callbacks
%%====================================================================
start (_Type, _Args) ->
  case mondriak_sup:start_link() of
    {ok, Pid} ->
      {ok, Pid};
    Error ->
      Error
  end.

stop (_State) ->
  ok.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
ensure_started(App) ->
  case application:start(App) of
    ok ->
      ok;
    {error, {already_started, App}} ->
      ok
  end.

%%====================================================================
%% Test functions
%%====================================================================
-ifdef(EUNIT).

-endif.
