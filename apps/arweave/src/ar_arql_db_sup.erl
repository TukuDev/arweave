-module(ar_arql_db_sup).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

%%%===================================================================
%%% Public API.
%%%===================================================================

start_link(Args) ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, Args).

%%%===================================================================
%%% Supervisor callbacks.
%%%===================================================================

init(Args) ->
	SupFlags = #{strategy => one_for_one, intensity => 50, period => 1},
	ChildSpec = #{ id => ar_arql_db, start => {ar_arql_db, start_link, [Args]} },
	{ok, {SupFlags, [ChildSpec]}}.
