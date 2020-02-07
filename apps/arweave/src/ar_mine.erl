-module(ar_mine).

-export([start/8, stop/1, mine/2]).
-export([validate/4, validate/3]).
-export([min_difficulty/1, genesis_difficulty/0, max_difficulty/0]).
-export([sha384_diff_to_randomx_diff/1]).

-include("ar.hrl").

-include_lib("eunit/include/eunit.hrl").

%%% A module for managing mining of blocks on the weave,

%% State record for miners
-record(state, {
	parent, % miners parent process (initiator)
	current_block, % current block held by node
	candidate_block = not_set, % the product of mining
	block_txs_pairs, % list of {BH, TXIDs} pairs for latest ?MAX_TX_ANCHOR_DEPTH blocks
	poa, % proof of access
	txs, % the set of txs to be mined
	timestamp, % the block timestamp used for the mining
	timestamp_refresh_timer, % reference for timer for updating the timestamp
	data_segment = <<>>, % the data segment generated for mining
	data_segment_duration, % duration in seconds of the last generation of the data segment
	reward_addr, % the mining reward address
	reward_wallet = not_set, % the mining reward wallet
	tags, % the block tags
	diff, % the current network difficulty
	delay = 0, % hashing delay used for testing
	max_miners = ?NUM_MINING_PROCESSES, % max mining process to start
	miners = [], % miner worker processes
	bds_base = not_generated, % part of the block data segment not changed during mining
	total_hashes_tried = 0, % the number of tried hashes, used to estimate the hashrate
	started_at = not_set % the timestamp when the mining begins, used to estimate the hashrate
}).

%% @doc Spawns a new mining process and returns its PID.
start(CurrentB, POA, RawTXs, RewardAddr, Tags, Parent, BlockTXPairs, BI) ->
	Fork_2_0 = ar_fork:height_2_0() ,
	CurrentHeight = CurrentB#block.height,
	NewVotables = case CurrentHeight + 1 of
		Fork_2_0 ->
			ar_votable:init();
		H when H > Fork_2_0 ->
			ar_votable:vote(CurrentB#block.votables);
		_ ->
			[]
	end,
	BlockPOA = case CurrentHeight + 1 >= Fork_2_0 of
		true ->
			POA;
		false ->
			undefined
	end,
	CandidateB = #block{
		height = CurrentB#block.height + 1,
		hash_list = ?BI_TO_BHL(BI),
		previous_block = CurrentB#block.indep_hash,
		hash_list_merkle = ar_block:compute_hash_list_merkle(CurrentB, BI),
		reward_addr = RewardAddr,
		poa = BlockPOA,
		votables = NewVotables,
		tags = Tags
	},
	start_server(
		#state {
			parent = Parent,
			current_block = CurrentB,
			poa = POA,
			data_segment_duration = 0,
			reward_addr = RewardAddr,
			tags = Tags,
			max_miners = ar_meta_db:get(max_miners),
			block_txs_pairs = BlockTXPairs,
			started_at = erlang:timestamp(),
			candidate_block = CandidateB
		},
		RawTXs
	).

%% @doc Stop a running mining server.
stop(PID) ->
	PID ! stop.

%% @doc Validate that a given hash/nonce satisfy the difficulty requirement.
validate(BDS, Nonce, Diff, Height) ->
	BDSHash = ar_weave:hash(BDS, Nonce, Height),
	case validate(BDSHash, Diff, Height) of
		true ->
			{valid, BDSHash};
		false ->
			{invalid, BDSHash}
	end.

%% @doc Validate that a given block data segment hash satisfies the difficulty requirement.
validate(BDSHash, Diff, Height) ->
	case ar_fork:height_1_8() of
		H when Height >= H ->
			binary:decode_unsigned(BDSHash, big) > Diff;
		_ ->
			case BDSHash of
				<< 0:Diff, _/bitstring >> ->
					true;
				_ ->
					false
			end
	end.

%% @doc Maximum linear difficulty.
%% Assumes using 256 bit RandomX hashes.
max_difficulty() ->
	erlang:trunc(math:pow(2, 256)).

-ifdef(DEBUG).
min_difficulty(_Height) ->
	1.
-else.
min_difficulty(Height) ->
	Diff = case Height >= ar_fork:height_1_7() of
		true ->
			min_randomx_difficulty();
		false ->
			min_sha384_difficulty()
	end,
	case Height >= ar_fork:height_1_8() of
		true ->
			ar_retarget:switch_to_linear_diff(Diff);
		false ->
			Diff
	end.
-endif.

-ifdef(DEBUG).
genesis_difficulty() ->
	1.
-else.
genesis_difficulty() ->
	Diff = case ar_fork:height_1_7() of
		0 ->
			randomx_genesis_difficulty();
		_ ->
			?DEFAULT_DIFF
	end,
	case ar_fork:height_1_8() of
		0 ->
			ar_retarget:switch_to_linear_diff(Diff);
		_ ->
			Diff
	end.
-endif.

sha384_diff_to_randomx_diff(Sha384Diff) ->
	max(Sha384Diff + ?RANDOMX_DIFF_ADJUSTMENT, min_randomx_difficulty()).

%% PRIVATE

%% @doc Takes a state and a set of transactions and return a new state with the
%% new set of transactions.
update_txs(
	S = #state {
		current_block = CurrentB,
		data_segment_duration = BDSGenerationDuration,
		block_txs_pairs = BlockTXPairs,
		reward_addr = RewardAddr,
		candidate_block = CandidateB
	},
	TXs
) ->
	NextBlockTimestamp = next_block_timestamp(BDSGenerationDuration),
	NextDiff = calc_diff(CurrentB, NextBlockTimestamp),
	ValidTXs = ar_tx_replay_pool:pick_txs_to_mine(
		BlockTXPairs,
		CurrentB#block.height,
		NextDiff,
		NextBlockTimestamp,
		CurrentB#block.wallet_list,
		TXs
	),
	NewBlockSize =
		lists:foldl(
			fun(TX, Acc) ->
				Acc + byte_size(TX#tx.data)
			end,
			0,
			ValidTXs
		),
	NewWeaveSize = CurrentB#block.weave_size + NewBlockSize,
	{FinderReward, _RewardPool} =
		ar_node_utils:calculate_reward_pool(
			CurrentB#block.reward_pool,
			ValidTXs,
			RewardAddr,
			CandidateB#block.poa,
			NewWeaveSize,
			CandidateB#block.height,
			NextDiff,
			NextBlockTimestamp
		),
	NewWalletList =
		ar_node_utils:apply_mining_reward(
			ar_node_utils:apply_txs(CurrentB#block.wallet_list, ValidTXs, CurrentB#block.height),
			RewardAddr,
			FinderReward,
			CandidateB#block.height
		),
	Fork_2_0 = ar_fork:height_2_0(),
	NewCandidateB = CandidateB#block{
		txs = [TX#tx.id || TX <- ValidTXs],
		tx_root = ar_block:generate_tx_root_for_block(ValidTXs),
		block_size = NewBlockSize,
		weave_size = NewWeaveSize,
		wallet_list = NewWalletList
	},
	{BDSBase, RewardWallet} = case CurrentB#block.height + 1 < Fork_2_0 of
		true ->
			{not_generated, not_set};
		false ->
			ar_block:generate_block_data_segment_base(NewCandidateB)
	end,
	update_data_segment(
		S#state{
			candidate_block = NewCandidateB,
			bds_base = BDSBase,
			reward_wallet = RewardWallet
		},
		ValidTXs,
		NextBlockTimestamp,
		NextDiff
	).

%% @doc Generate a new timestamp to be used in the next block. To compensate for
%% the time it takes to generate the block data segment, adjust the timestamp
%% with the same time it took to generate the block data segment the last time.
next_block_timestamp(BDSGenerationDuration) ->
	os:system_time(seconds) + BDSGenerationDuration.

%% @doc Given a block calculate the difficulty to mine on for the next block.
%% Difficulty is retargeted each ?RETARGET_BlOCKS blocks, specified in ar.hrl
%% This is done in attempt to maintain on average a fixed block time.
calc_diff(CurrentB, NextBlockTimestamp) ->
	ar_retarget:maybe_retarget(
		CurrentB#block.height + 1,
		CurrentB#block.diff,
		NextBlockTimestamp,
		CurrentB#block.last_retarget
	).

%% @doc Generate a new data_segment and update the timestamp and diff.
update_data_segment(S = #state { txs = TXs }) ->
	update_data_segment(S, TXs).

%% @doc Generate a new data_segment and update the timestamp, diff and transactions.
update_data_segment(
	S = #state {
		data_segment_duration = BDSGenerationDuration,
		current_block = CurrentB
	},
	TXs
) ->
	BlockTimestamp = next_block_timestamp(BDSGenerationDuration),
	Diff = calc_diff(CurrentB, BlockTimestamp),
	update_data_segment(S, TXs, BlockTimestamp, Diff).

update_data_segment(S, TXs, BlockTimestamp, Diff) ->
	CandidateB = S#state.candidate_block,
	case CandidateB#block.height < ar_fork:height_2_0() of
		true ->
			update_data_segment_pre_2_0(S, TXs, BlockTimestamp, Diff);
		false ->
			update_data_segment_post_2_0(S, TXs, BlockTimestamp, Diff)
	end.

update_data_segment_pre_2_0(S, TXs, BlockTimestamp, Diff) ->
	#state{ candidate_block = CandidateBlock } = S,
	RewardAddr = case S#state.reward_addr of
		unclaimed -> <<>>;
		R -> R
	end,
	{DurationMicros, {NewBDSBase, BDS}} =
		case S#state.bds_base of
			not_generated ->
				timer:tc(fun() ->
					ar_block:generate_block_data_segment_and_pieces(
						S#state.current_block,
						S#state.poa,
						TXs,
						RewardAddr,
						BlockTimestamp,
						S#state.tags
					)
				end);
			BDSBase ->
				timer:tc(fun() ->
					ar_block:refresh_block_data_segment_timestamp(
						BDSBase,
						S#state.current_block,
						S#state.poa,
						TXs,
						RewardAddr,
						BlockTimestamp
					)
				end)
		end,
	NewS = S#state {
		timestamp = BlockTimestamp,
		diff = Diff,
		txs = TXs,
		data_segment = BDS,
		data_segment_duration = round(DurationMicros / 1000000),
		bds_base = NewBDSBase,
		candidate_block = CandidateBlock#block{
			timestamp = BlockTimestamp,
			diff = Diff
		}
	},
	reschedule_timestamp_refresh(NewS).

update_data_segment_post_2_0(S, TXs, BlockTimestamp, Diff) ->
	#state{
		current_block = CurrentB,
		candidate_block = CandidateB,
		reward_addr = RewardAddr,
		poa = POA,
		bds_base = BDSBase,
		reward_wallet = RewardWallet
	} = S,
	NewLastRetarget =
		case ar_retarget:is_retarget_height(CandidateB#block.height) of
			true -> BlockTimestamp;
			false -> CurrentB#block.last_retarget
		end,
	{FinderReward, RewardPool} =
		ar_node_utils:calculate_reward_pool(
			CurrentB#block.reward_pool,
			TXs,
			RewardAddr,
			POA,
			CandidateB#block.weave_size,
			CandidateB#block.height,
			Diff,
			BlockTimestamp
		),
	WL = case RewardWallet of
		not_in_the_list ->
			[];
		_ ->
			[RewardWallet]
	end,
	NewRewardWallet =
		case ar_node_utils:apply_mining_reward(WL, RewardAddr, FinderReward, CandidateB#block.height) of
			[RW] ->
				RW;
			[] ->
				not_in_the_list
		end,
	CDiff = ar_difficulty:next_cumulative_diff(
		CurrentB#block.cumulative_diff,
		Diff,
		CandidateB#block.height
	),
	{DurationMicros, NewBDS} = timer:tc(
		fun() ->
			ar_block:generate_block_data_segment(
				BDSBase,
				CandidateB#block.hash_list_merkle,
				#{
					timestamp => BlockTimestamp,
					last_retarget => NewLastRetarget,
					diff => Diff,
					cumulative_diff => CDiff,
					reward_pool => RewardPool,
					reward_wallet => NewRewardWallet
				}
			)
		end
	),
	NewCandidateB = CandidateB#block{
		timestamp = BlockTimestamp,
		last_retarget = NewLastRetarget,
		diff = Diff,
		cumulative_diff = CDiff,
		reward_pool = RewardPool
	},
	NewS = S#state {
		timestamp = BlockTimestamp,
		diff = Diff,
		data_segment = NewBDS,
		data_segment_duration = round(DurationMicros / 1000000),
		txs = TXs,
		candidate_block = NewCandidateB,
		reward_wallet = NewRewardWallet
	},
	reschedule_timestamp_refresh(NewS).

reschedule_timestamp_refresh(S = #state{
	timestamp_refresh_timer = Timer,
	data_segment_duration = BDSGenerationDuration,
	txs = TXs
}) ->
	timer:cancel(Timer),
	case ?MINING_TIMESTAMP_REFRESH_INTERVAL - BDSGenerationDuration  of
		TimeoutSeconds when TimeoutSeconds =< 0 ->
			TXIDs = lists:map(fun(TX) -> TX#tx.id end, TXs),
			ar:warn([
				ar_mine,
				slow_data_segment_generation,
				{duration, BDSGenerationDuration},
				{timestamp_refresh_interval, ?MINING_TIMESTAMP_REFRESH_INTERVAL},
				{txs, lists:map(fun ar_util:encode/1, lists:sort(TXIDs))}
			]),
			self() ! refresh_timestamp,
			S#state{ timestamp_refresh_timer = no_timer };
		TimeoutSeconds ->
			case timer:send_after(TimeoutSeconds * 1000, refresh_timestamp) of
				{ok, Ref} ->
					S#state{ timestamp_refresh_timer = Ref };
				{error, Reason} ->
					ar:err("ar_mine: Reschedule timestamp refresh failed: ~p", [Reason]),
					S
			end
	end.

%% @doc Start the main mining server.
start_server(S, TXs) ->
	spawn(fun() ->
		server(start_miners(update_txs(S, TXs)))
	end).

%% @doc The main mining server.
server(
	S = #state {
		parent = Parent,
		miners = Miners,
		current_block = #block { indep_hash = CurrentBH } = CurrentB,
		poa = POA,
		total_hashes_tried = TotalHashesTried,
		started_at = StartedAt,
		data_segment = BDS,
		reward_addr = RewardAddr,
		reward_wallet = RewardWallet,
		candidate_block = #block { diff = Diff, timestamp = Timestamp } = CandidateB
	}
) ->
	receive
		% Stop the mining process and all the workers.
		stop ->
			stop_miners(Miners),
			log_performance(TotalHashesTried, StartedAt),
			ok;
		%% The block timestamp must be reasonable fresh since it's going to be
		%% validated on the remote nodes when it's propagated to them. Only blocks
		%% with a timestamp close to current time will be accepted in the propagation.
		refresh_timestamp ->
			server(restart_miners(update_data_segment(S)));
		%% Count the number of hashes tried by all workers.
		{hashes_tried, HashesTried} ->
			server(S#state { total_hashes_tried = TotalHashesTried + HashesTried });
		%% Handle a potential solution for the mining puzzle.
		%% Returns the solution back to the node to verify and ends the process.
		{solution, Hash, Nonce, MinedTXs, Diff, Timestamp} ->
			ar:info(
				[
					{event, miner_found_nonce},
					{pid, self()}
				]
			),
			Fork_2_0 = ar_fork:height_2_0(),
			NewBBeforeHash = case CandidateB#block.height >= Fork_2_0 of
				true ->
					CandidateB#block{
						nonce = Nonce,
						hash = Hash,
						wallet_list = lists:keyreplace(RewardAddr, 1, CandidateB#block.wallet_list, RewardWallet)
					};
				false ->
					{FinderReward, RewardPool} =
						ar_node_utils:calculate_reward_pool(
							CurrentB#block.reward_pool,
							MinedTXs,
							RewardAddr,
							POA,
							CandidateB#block.weave_size,
							CandidateB#block.height,
							CandidateB#block.diff,
							CandidateB#block.timestamp
						),
					NewWalletList = ar_node_utils:apply_mining_reward(
						ar_node_utils:apply_txs(CurrentB#block.wallet_list, MinedTXs, CurrentB#block.height),
						RewardAddr,
						FinderReward,
						CandidateB#block.height
					),
					NewCDiff = ar_difficulty:next_cumulative_diff(
						CurrentB#block.cumulative_diff,
						CandidateB#block.diff,
						CandidateB#block.height
					),
					NewLastRetarget = case ar_retarget:is_retarget_height(CurrentB#block.height) of
						true -> CandidateB#block.timestamp;
						false -> CurrentB#block.last_retarget
					end,
					CandidateB#block{
						nonce = Nonce,
						hash = Hash,
						cumulative_diff = NewCDiff,
						last_retarget = NewLastRetarget,
						wallet_list = NewWalletList,
						reward_pool = RewardPool
					}
			end,
			IndepHash =
				case CandidateB#block.height >= Fork_2_0 of
					true ->
						ar_weave:indep_hash_post_fork_2_0(BDS, Hash, Nonce);
					false ->
						ar_weave:indep_hash(NewBBeforeHash)
				end,
			NewB = NewBBeforeHash#block{ indep_hash = IndepHash },
			Parent ! {work_complete, CurrentBH, NewB, MinedTXs, BDS, POA, TotalHashesTried},
			log_performance(TotalHashesTried, StartedAt),
			stop_miners(Miners);
		{solution, _, _, _, _, _} ->
			%% A stale solution.
			server(S)
	end.

log_performance(TotalHashesTried, StartedAt) ->
	Time = timer:now_diff(erlang:timestamp(), StartedAt),
	ar:info([ar_mine, stopping_miner, {miner_hashes_per_second, TotalHashesTried / (Time / 1000000)}]).

%% @doc Start the workers and return the new state.
start_miners(S = #state {max_miners = MaxMiners}) ->
	Miners =
		lists:map(
			fun(_) -> spawn(?MODULE, mine, [S, self()]) end,
			lists:seq(1, MaxMiners)
		),
	S#state {miners = Miners}.

%% @doc Stop all workers.
stop_miners(Miners) ->
	lists:foreach(
		fun(PID) ->
			exit(PID, stop)
		end,
		Miners
	).

%% @doc Stop and then start the workers again and return the new state.
restart_miners(S) ->
	stop_miners(S#state.miners),
	start_miners(S).

%% @doc A worker process to hash the data segment searching for a solution
%% for the given diff.
mine(
	#state {
		data_segment = BDS,
		diff = Diff,
		txs = TXs,
		timestamp = Timestamp,
		current_block = #block{ height = CurrentHeight }
	},
	Supervisor
) ->
	process_flag(priority, low),
	{Nonce, Hash} = find_nonce(BDS, Diff, CurrentHeight + 1, Supervisor),
	Supervisor ! {solution, Hash, Nonce, TXs, Diff, Timestamp}.

find_nonce(BDS, Diff, Height, Supervisor) ->
	case Height >= ar_fork:height_1_7() of
		true ->
			case randomx_hasher(Height) of
				{ok, Hasher} ->
					StartNonce = crypto:strong_rand_bytes(256 div 8),
					find_nonce(BDS, Diff, Height, StartNonce, Hasher, Supervisor);
				not_found ->
					ar:info("Mining is waiting on RandomX initialization"),
					timer:sleep(30 * 1000),
					find_nonce(BDS, Diff, Height, Supervisor)
			end;
		false ->
			%% The subsequent nonces will be 384 bits, so that's a pretty nice but still
			%% arbitrary size for the initial nonce.
			StartNonce = crypto:strong_rand_bytes(384 div 8),
			Hasher = fun(Nonce, InputBDS, _Diff) ->
				{crypto:hash(?MINING_HASH_ALG, << Nonce/binary, InputBDS/binary >>), Nonce, 1}
			end,
			find_nonce(BDS, Diff, Height, StartNonce, Hasher, Supervisor)
	end.

%% Use RandomX fast-mode, where hashing is fast but initialization is slow.
randomx_hasher(Height) ->
	case ar_randomx_state:randomx_state_by_height(Height) of
		{state, {fast, FastState}} ->
			Hasher = fun(Nonce, BDS, Diff) ->
				ar_mine_randomx:bulk_hash_fast(FastState, Nonce, BDS, Diff)
			end,
			{ok, Hasher};
		{state, {light, _}} ->
			not_found;
		{key, _} ->
			not_found
	end.

find_nonce(BDS, Diff, Height, Nonce, Hasher, Supervisor) ->
	{BDSHash, HashNonce, HashesTried} = Hasher(Nonce, BDS, Diff),
	Supervisor ! {hashes_tried, HashesTried},
	case validate(BDSHash, Diff, Height) of
		false ->
			%% Re-use the hash as the next nonce, since we get it for free.
			find_nonce(BDS, Diff, Height, BDSHash, Hasher, Supervisor);
		true ->
			{HashNonce, BDSHash}
	end.

-ifdef(DEBUG).
min_randomx_difficulty() -> 1.
-else.
min_randomx_difficulty() -> min_sha384_difficulty() + ?RANDOMX_DIFF_ADJUSTMENT.
min_sha384_difficulty() -> 31.
randomx_genesis_difficulty() -> ?DEFAULT_DIFF.
-endif.

%% Tests

%% @doc Test that found nonces abide by the difficulty criteria.
basic_test_() ->
	ar_test_fork:test_on_fork(
		height_2_0,
		0,
		fun() ->
			[B0] = ar_weave:init([]),
			ar_node:start([], [B0]),
			[B1 | _] = ar_weave:add([B0], []),
			start(B1, B1#block.poa, [], unclaimed, [], self(), [], [{B0#block.indep_hash, 0}]),
			assert_mine_output(B1, B1#block.poa, [])
		end
	).

basic_pre_fork_2_0_test() ->
	[B0] = ar_weave:init([]),
	ar_node:start([], [B0]),
	[B1 | _] = ar_weave:add([B0], []),
	RecallB = B0,
	start(B1, RecallB, [], unclaimed, [], self(), [], [{B0#block.indep_hash, 0}]),
	assert_mine_output(B1, RecallB, []).

%% @doc Ensure that the block timestamp gets updated regularly while mining.
timestamp_refresh_test_() ->
	{timeout, 20, fun() ->
		[B0] = ar_weave:init(),
		B = B0,
		RecallB = B0,
		%% Start mining with a high enough difficulty, so that the block
		%% timestamp gets refreshed at least once. Since we might be unlucky
		%% and find the block too fast, we retry until it succeeds.
		Diff = 4,
		Run = fun(_) ->
			TXs = [],
			start(B, RecallB, TXs, unclaimed, [], Diff, self(), []),
			StartTime = os:system_time(seconds),
			{_, MinedTimestamp} = assert_mine_output(B, RecallB, TXs),
			MinedTimestamp > StartTime
		end,
		?assert(lists:any(Run, lists:seq(1, 20)))
	end}.

%% @doc Ensures ar_mine can be started and stopped.
start_stop_test() ->
	B0 = ar_weave:init(),
	ar_node:start([], B0),
	B1 = ar_weave:add(B0, []),
	B = hd(B1),
	RecallB = hd(B0),
	VeryHighDiff = trunc(math:pow(2, 1000)),
	PID = start(B, RecallB, [], unclaimed, [], VeryHighDiff, self(), []),
	timer:sleep(500),
	assert_alive(PID),
	stop(PID),
	assert_not_alive(PID, 3000).

%% @doc Ensures a miner can be started and stopped.
miner_start_stop_test() ->
	[B] = ar_weave:init(),
	S = #state{ diff = trunc(math:pow(2, 1000)), current_block = B },
	PID = spawn(?MODULE, mine, [S, self()]),
	timer:sleep(500),
	assert_alive(PID),
	stop_miners([PID]),
	assert_not_alive(PID, 3000).

assert_mine_output(B, POA, TXs) ->
	receive
		{work_complete, BH, NewB, MinedTXs, POA, _} ->
			?assertEqual(BH, B#block.indep_hash),
			?assertEqual(lists:sort(TXs), lists:sort(MinedTXs)),
			BDS = ar_block:generate_block_data_segment(
				B,
				POA,
				TXs,
				<<>>,
				NewB#block.timestamp,
				[]
			),
			?assertEqual(
				ar_weave:hash(BDS, NewB#block.nonce, B#block.height),
				NewB#block.hash
			),
			?assert(binary:decode_unsigned(NewB#block.hash) > NewB#block.diff),
			{NewB#block.diff, NewB#block.timestamp}
	after 20000 ->
		error(timeout)
	end.

assert_alive(PID) ->
	?assert(is_process_alive(PID)).

assert_not_alive(PID, Timeout) ->
	Do = fun () -> not is_process_alive(PID) end,
	?assert(ar_util:do_until(Do, 50, Timeout)).
