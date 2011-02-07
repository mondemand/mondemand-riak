-module (mondriak_sup).

-behaviour (supervisor).

-ifdef(HAVE_EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%====================================================================
%% API functions
%%====================================================================
%% @spec start_link() -> ServerRet
%% @doc API for starting the supervisor.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%====================================================================
%% supervisor callbacks
%%====================================================================
%% @spec init([]) -> SupervisorTree
%% @doc supervisor callback.
init([]) ->
  { ok,
    {
      { one_for_one, 10, 10 },
      [
        { mondriak,                                % child spec id
          { mondriak, start_link, [] },            % child function to call
          permanent,                               % always restart
          2000,                                    % time to wait for child stop
          worker,                                  % type of child
          [ mondriak ]                             % modules used by child
        }
      ]
    }
  }.

%%====================================================================
%% Test functions
%%====================================================================
-ifdef(EUNIT).

-endif.
