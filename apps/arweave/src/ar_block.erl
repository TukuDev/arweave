-module(ar_block).

-export([block_to_binary/1, block_field_size_limit/1]).
-export([get_recall_block/5]).
-export([verify_dep_hash/2, verify_indep_hash/1, verify_timestamp/1]).
-export([verify_height/2, verify_last_retarget/2, verify_previous_block/2]).
-export([verify_block_hash_list/2, verify_wallet_list/4, verify_weave_size/3]).
-export([verify_cumulative_diff/2, verify_block_hash_list_merkle/3]).
-export([verify_tx_root/1]).
-export([hash_wallet_list/1]).
-export([encrypt_block/2, encrypt_block/3]).
-export([encrypt_full_block/2, encrypt_full_block/3]).
-export([decrypt_block/4]).
-export([generate_block_key/2]).
-export([generate_block_data_segment_pre_2_0/6]).
-export([generate_block_data_segment/1, generate_block_data_segment/3, generate_block_data_segment_base/1]).
-export([generate_hash_list_for_block/2]).
-export([generate_tx_root_for_block/1, generate_size_tagged_list_from_txs/1]).
-export([generate_block_data_segment_and_pieces/6, refresh_block_data_segment_timestamp/6]).
-export([generate_tx_tree/1, generate_tx_tree/2]).
-export([join_v1_v2_hash_list/3]).
-export([compute_hash_list_merkle/2]).

-include("ar.hrl").
-include_lib("eunit/include/eunit.hrl").

%% @doc Generate a re-producible hash from a wallet list.
hash_wallet_list(WalletListHash) when is_binary(WalletListHash) -> WalletListHash;
hash_wallet_list(WalletList) ->
	Bin =
		<<
			<< Addr/binary, (binary:encode_unsigned(Balance))/binary, LastTX/binary >>
		||
			{Addr, Balance, LastTX} <- WalletList
		>>,
	crypto:hash(?HASH_ALG, Bin).

%% @doc Generate the TX tree and set the TX root for a block.
generate_tx_tree(B) ->
	generate_tx_tree(B, generate_size_tagged_list_from_txs(B#block.txs)).
generate_tx_tree(B, SizeTaggedTXs) ->
	{Root, Tree} = ar_merkle:generate_tree(SizeTaggedTXs),
	B#block { tx_tree = Tree, tx_root = Root }.

generate_size_tagged_list_from_txs(TXs) ->
	lists:reverse(
		element(2,
			lists:foldl(
				fun
					({TXID, Size}, {Pos, List}) ->
						End = Pos + Size,
						{End, [{TXID, End} | List]};
					(TX, {Pos, List}) ->
						End = Pos + TX#tx.data_size,
						{End, [{TX#tx.id, End} | List]}
				end,
				{0, []},
				TXs
			)
		)
	).

%% @doc Find the appropriate block hash list for a block, from a
%% block index.
generate_hash_list_for_block(_BlockOrHash, []) -> [];
generate_hash_list_for_block(B, BI) when ?IS_BLOCK(B) ->
	generate_hash_list_for_block(B#block.indep_hash, BI);
generate_hash_list_for_block(Hash, BI) ->
	do_generate_hash_list_for_block(Hash, BI).

do_generate_hash_list_for_block(_, []) ->
	error(cannot_generate_hash_list);
do_generate_hash_list_for_block(IndepHash, [{IndepHash, _} | BI]) -> ?BI_TO_BHL(BI);
do_generate_hash_list_for_block(IndepHash, [_ | Rest]) ->
	do_generate_hash_list_for_block(IndepHash, Rest).

%% @doc Encrypt a recall block. Encryption key is derived from
%% the contents of the recall block and the hash of the current block
encrypt_block(R, B) when ?IS_BLOCK(B) -> encrypt_block(R, B#block.indep_hash);
encrypt_block(R, Hash) ->
	Recall =
		ar_serialize:jsonify(
			ar_serialize:block_to_json_struct(R)
		),
	encrypt_block(
		Recall,
		crypto:hash(?HASH_ALG,<<Hash/binary, Recall/binary>>),
		_Nonce = binary:part(Hash, 0, 16)
	).
encrypt_block(R, Key, Nonce) when ?IS_BLOCK(R) ->
	encrypt_block(
		ar_serialize:jsonify(
			ar_serialize:block_to_json_struct(R)
		),
		Key,
		Nonce
	);
encrypt_block(Recall, Key, Nonce) ->
	PlainText = pad_to_length(Recall),
	CipherText =
		crypto:block_encrypt(
			aes_cbc,
			Key,
			Nonce,
			PlainText
		),
	CipherText.

%% @doc Decrypt a recall block
decrypt_block(B, CipherText, Key, Nonce)
		when ?IS_BLOCK(B)->
	decrypt_block(B#block.indep_hash, CipherText, Key, Nonce);
decrypt_block(_Hash, CipherText, Key, Nonce) ->
	if
		(Key == <<>>) or (Nonce == <<>>) -> unavailable;
		true ->
			PaddedPlainText =
				crypto:block_decrypt(
					aes_cbc,
					Key,
					Nonce,
					CipherText
				),
			PlainText = binary_to_list(unpad_binary(PaddedPlainText)),
			RJSON = ar_serialize:dejsonify(PlainText),
			ar_serialize:json_struct_to_block(RJSON)
	end.

%% @doc Encrypt a recall block. Encryption key is derived from
%% the contents of the recall block and the hash of the current block
encrypt_full_block(R, B) when ?IS_BLOCK(B) ->
	encrypt_full_block(R, B#block.indep_hash);
encrypt_full_block(R, Hash) ->
	Recall =
		ar_serialize:jsonify(
			ar_serialize:full_block_to_json_struct(R)
		),
	encrypt_full_block(
		Recall,
		crypto:hash(?HASH_ALG,<<Hash/binary, Recall/binary>>),
		_Nonce = binary:part(Hash, 0, 16)
	).
encrypt_full_block(R, Key, Nonce) when ?IS_BLOCK(R) ->
	encrypt_full_block(
		ar_serialize:jsonify(
			ar_serialize:full_block_to_json_struct(R)
		),
		Key,
		Nonce
	);
encrypt_full_block(Recall, Key, Nonce) ->
	PlainText = pad_to_length(Recall),
	CipherText =
		crypto:block_encrypt(
			aes_cbc,
			Key,
			Nonce,
			PlainText
		),
	CipherText.

%% @doc Decrypt a recall block
decrypt_full_block(CipherText, Key, Nonce) ->
	if
		(Key == <<>>) or (Nonce == <<>>) -> unavailable;
		true ->
			PaddedPlainText =
				crypto:block_decrypt(
					aes_cbc,
					Key,
					Nonce,
					CipherText
				),
			PlainText = binary_to_list(unpad_binary(PaddedPlainText)),
			RJSON = ar_serialize:dejsonify(PlainText),
			ar_serialize:json_struct_to_full_block(RJSON)
	end.


%% @doc derive the key for a given recall block, given the
%% recall block and current block
generate_block_key(R, B) when ?IS_BLOCK(B) ->
	generate_block_key(R, B#block.indep_hash);
generate_block_key(R, Hash) ->
	Recall =
		ar_serialize:jsonify(
			ar_serialize:full_block_to_json_struct(R)
		),
	crypto:hash(?HASH_ALG,<<Hash/binary, Recall/binary>>).

%% @doc Pad a binary to the nearest mutliple of the block
%% cipher length (32 bytes)
pad_to_length(Binary) ->
	Pad = (32 - ((byte_size(Binary)+1) rem 32)),
	<<Binary/binary, 1, 0:(Pad*8)>>.

%% @doc Unpad a binary padded using the method above
unpad_binary(Binary) ->
	ar_util:rev_bin(do_unpad_binary(ar_util:rev_bin(Binary))).
do_unpad_binary(Binary) ->
	case Binary of
		<< 0:8, Rest/binary >> -> do_unpad_binary(Rest);
		<< 1:8, Rest/binary >> -> Rest
	end.

%% @doc Generate a hashable binary from a #block object.
block_to_binary(B) ->
	<<
		(B#block.nonce)/binary,
		(B#block.previous_block)/binary,
		(list_to_binary(integer_to_list(B#block.timestamp)))/binary,
		(list_to_binary(integer_to_list(B#block.last_retarget)))/binary,
		(list_to_binary(integer_to_list(B#block.diff)))/binary,
		(list_to_binary(integer_to_list(B#block.height)))/binary,
		(B#block.hash)/binary,
		(B#block.indep_hash)/binary,
		(
			binary:list_to_bin(
				lists:map(
					fun ar_tx:tx_to_binary/1,
					lists:sort(ar_storage:read_tx(B#block.txs))
				)
			)
		)/binary,
		(list_to_binary(B#block.hash_list))/binary,
		(
			binary:list_to_bin(
				lists:map(
					fun ar_wallet:to_binary/1,
					ar_storage:read_wallet_list(B#block.wallet_list)
				)
			)
		)/binary,
		(
			case is_atom(B#block.reward_addr) of
				true -> <<>>;
				false -> B#block.reward_addr
			end
		)/binary,
		(list_to_binary(B#block.tags))/binary,
		(list_to_binary(integer_to_list(B#block.weave_size)))/binary
	>>.

%% @doc Given a block checks that the lengths conform to the specified limits.
block_field_size_limit(B = #block { reward_addr = unclaimed }) ->
	block_field_size_limit(B#block { reward_addr = <<>> });
block_field_size_limit(B) ->
	DiffBytesLimit = case ar_fork:height_1_8() of
		H when B#block.height >= H ->
			78;
		_ ->
			10
	end,
	{ChunkSize, TXPathSize, DataPathSize} =
		case B#block.poa of
			POA when is_record(POA, poa) ->
				{
					byte_size((B#block.poa)#poa.chunk),
					byte_size((B#block.poa)#poa.tx_path),
					byte_size((B#block.poa)#poa.data_path)
				};
			_ -> {0, 0, 0}
		end,
	Check = (byte_size(B#block.nonce) =< 512) and
		(byte_size(B#block.previous_block) =< 48) and
		(byte_size(integer_to_binary(B#block.timestamp)) =< 12) and
		(byte_size(integer_to_binary(B#block.last_retarget)) =< 12) and
		(byte_size(integer_to_binary(B#block.diff)) =< DiffBytesLimit) and
		(byte_size(integer_to_binary(B#block.height)) =< 20) and
		(byte_size(B#block.hash) =< 48) and
		(byte_size(B#block.indep_hash) =< 48) and
		(byte_size(B#block.reward_addr) =< 32) and
		(byte_size(list_to_binary(B#block.tags)) =< 2048) and
		(byte_size(integer_to_binary(B#block.weave_size)) =< 64) and
		(byte_size(integer_to_binary(B#block.block_size)) =< 64) and
		(ChunkSize =< ?DATA_CHUNK_SIZE) and
		(TXPathSize =< ?MAX_PATH_SIZE) and
		(DataPathSize =< ?MAX_PATH_SIZE),
	% Report of wrong field size.
	case Check of
		false ->
			ar:report(
				[
					invalid_block_field_size,
					{nonce, byte_size(B#block.nonce)},
					{previous_block, byte_size(B#block.previous_block)},
					{timestamp, byte_size(integer_to_binary(B#block.timestamp))},
					{last_retarget, byte_size(integer_to_binary(B#block.last_retarget))},
					{diff, byte_size(integer_to_binary(B#block.diff))},
					{height, byte_size(integer_to_binary(B#block.height))},
					{hash, byte_size(B#block.hash)},
					{indep_hash, byte_size(B#block.indep_hash)},
					{reward_addr, byte_size(B#block.reward_addr)},
					{tags, byte_size(list_to_binary(B#block.tags))},
					{weave_size, byte_size(integer_to_binary(B#block.weave_size))},
					{block_size, byte_size(integer_to_binary(B#block.block_size))}
				]
			);
		_ ->
			ok
	end,
	Check.

compute_hash_list_merkle(B, BI) ->
	NewHeight = B#block.height + 1,
	Fork_2_0 = ar_fork:height_2_0(),
	case NewHeight of
		_ when NewHeight < ?FORK_1_6 ->
			<<>>;
		?FORK_1_6 ->
			ar_unbalanced_merkle:hash_list_to_merkle_root(B#block.hash_list);
		_ when NewHeight < Fork_2_0 ->
			ar_unbalanced_merkle:root(B#block.hash_list_merkle, B#block.indep_hash);
		Fork_2_0 ->
			ar_unbalanced_merkle:block_index_to_merkle_root(
				[{B#block.indep_hash, B#block.weave_size} | BI]
			);
		_ ->
			ar_unbalanced_merkle:root(
				B#block.hash_list_merkle,
				{B#block.indep_hash, B#block.weave_size},
				fun ar_unbalanced_merkle:hash_block_index_entry/1
			)
	end.

%% @doc Generate a block data segment.
%% Block data segment is combined with a nonce to compute a PoW hash.
%% Also, it is combined with a nonce, the corresponding PoW hash, and
%% the merkle root of the block index to produce the independent hash.
generate_block_data_segment(B) ->
	{BDSBase, RewardWallet} = generate_block_data_segment_base(B),
	generate_block_data_segment(
		BDSBase,
		B#block.hash_list_merkle,
		#{
			timestamp => B#block.timestamp,
			last_retarget => B#block.last_retarget,
			diff => B#block.diff,
			cumulative_diff => B#block.cumulative_diff,
			reward_pool => B#block.reward_pool,
			reward_wallet => RewardWallet
		}
	).

generate_block_data_segment(BDSBase, BlockIndexMerkle, TimeDependentParams) ->
	#{
		timestamp := Timestamp,
		last_retarget := LastRetarget,
		diff := Diff,
		cumulative_diff := CDiff,
		reward_pool := RewardPool,
		reward_wallet := RewardWallet
	} = TimeDependentParams,
	RewardWalletPreimage =
		case RewardWallet of
			not_in_the_list ->
				<<"unclaimed">>;
			{A, Balance, L} ->
				[A, integer_to_binary(Balance), L]
		end,
	ar_deep_hash:hash([
		BDSBase,
		integer_to_binary(Timestamp),
		integer_to_binary(LastRetarget),
		integer_to_binary(Diff),
		integer_to_binary(CDiff),
		integer_to_binary(RewardPool),
		RewardWalletPreimage,
		BlockIndexMerkle
	]).

%% @doc Generate a hash, which is used to produce a block data segment,
%% when combined with the time-dependent parameters, which frequently
%% change during mining - timestamp, last retarget timestamp, difficulty,
%% cumulative difficulty, miner's wallet, reward pool. Also excludes
%% the merkle root of the block index, which is hashed with the rest
%% as the last step, to allow verifiers to quickly validate PoW against
%% the current state.
generate_block_data_segment_base(B) ->
	{RewardWallet, WalletList} =
		case lists:keytake(B#block.reward_addr, 1, B#block.wallet_list) of
			{value, R, W} ->
				{R, W};
			false ->
				{not_in_the_list, B#block.wallet_list}
		end,
	BDSBase = ar_deep_hash:hash([
		integer_to_binary(B#block.height),
		B#block.previous_block,
		B#block.tx_root,
		integer_to_binary(B#block.block_size),
		integer_to_binary(B#block.weave_size),
		[[A, integer_to_binary(Balance), L] || {A, Balance, L} <- WalletList],
		case B#block.reward_addr of
			unclaimed ->
				<<"unclaimed">>;
			_ ->
				B#block.reward_addr
		end,
		ar_tx:tags_to_list(B#block.tags),
		lists:map(
			fun({Name, Value}) ->
				[list_to_binary(Name), integer_to_binary(Value)]
			end,
			B#block.votables
		),
		poa_to_list(B#block.poa)
	]),
	{BDSBase, RewardWallet}.

poa_to_list(POA) ->
	[
		integer_to_binary(POA#poa.option),
		POA#poa.block_indep_hash,
		case POA#poa.tx_id of
			undefined -> <<>>;
			TXID -> TXID
		end,
		POA#poa.tx_root,
		POA#poa.tx_path,
		integer_to_binary(POA#poa.data_size),
		POA#poa.data_root,
		POA#poa.data_path,
		POA#poa.chunk
	].

%% @docs Generate a hashable data segment for a block from the preceding block,
%% the preceding block's recall block, TXs to be mined, reward address and tags.
generate_block_data_segment_pre_2_0(PrecedingB, POA, [unavailable], RewardAddr, Time, Tags) ->
	generate_block_data_segment_pre_2_0(
		PrecedingB,
		POA,
		[],
		RewardAddr,
		Time,
		Tags
	);
generate_block_data_segment_pre_2_0(PrecedingB, POA, TXs, unclaimed, Time, Tags) ->
	generate_block_data_segment_pre_2_0(
		PrecedingB,
		POA,
		TXs,
		<<>>,
		Time,
		Tags
	);
generate_block_data_segment_pre_2_0(PrecedingB, POA, TXs, RewardAddr, Time, Tags) ->
	{_, BDS} = generate_block_data_segment_and_pieces(PrecedingB, POA, TXs, RewardAddr, Time, Tags),
	BDS.

generate_block_data_segment_and_pieces(PrecedingB, POA, TXs, RewardAddr, Time, Tags) ->
	NewHeight = PrecedingB#block.height + 1,
	Retarget =
		case ar_retarget:is_retarget_height(NewHeight) of
			true -> Time;
			false -> PrecedingB#block.last_retarget
		end,
	WeaveSize = PrecedingB#block.weave_size +
		lists:foldl(
			fun(TX, Acc) ->
				Acc + byte_size(TX#tx.data)
			end,
			0,
			TXs
		),
	NewDiff = ar_retarget:maybe_retarget(
		PrecedingB#block.height + 1,
		PrecedingB#block.diff,
		Time,
		PrecedingB#block.last_retarget
	),
	{FinderReward, RewardPool} =
		ar_node_utils:calculate_reward_pool(
			PrecedingB#block.reward_pool,
			TXs,
			RewardAddr,
			POA,
			WeaveSize,
			PrecedingB#block.height + 1,
			NewDiff,
			Time
		),
	NewWalletList =
		ar_node_utils:apply_mining_reward(
			ar_node_utils:apply_txs(PrecedingB#block.wallet_list, TXs, PrecedingB#block.height),
			RewardAddr,
			FinderReward,
			length(PrecedingB#block.hash_list) - 1
		),
	MR =
		case PrecedingB#block.height >= ?FORK_1_6 of
			true -> PrecedingB#block.hash_list_merkle;
			false -> <<>>
		end,
	Pieces = [
		<<
			(PrecedingB#block.indep_hash)/binary,
			(PrecedingB#block.hash)/binary
		>>,
		<<
			(integer_to_binary(Time))/binary,
			(integer_to_binary(Retarget))/binary
		>>,
		<<
			(integer_to_binary(PrecedingB#block.height + 1))/binary,
			(
				list_to_binary(
					[PrecedingB#block.indep_hash | PrecedingB#block.hash_list]
				)
			)/binary
		>>,
		<<
			(
				binary:list_to_bin(
					lists:map(
						fun ar_wallet:to_binary/1,
						NewWalletList
					)
				)
			)/binary
		>>,
		<<
			(
				case is_atom(RewardAddr) of
					true -> <<>>;
					false -> RewardAddr
				end
			)/binary,
			(list_to_binary(Tags))/binary
		>>,
		<<
			(integer_to_binary(RewardPool))/binary
		>>,
		<<
			(block_to_binary(POA))/binary,
			(
				binary:list_to_bin(
					lists:map(
						fun ar_tx:tx_to_binary/1,
						TXs
					)
				)
			)/binary,
			MR/binary
		>>
	],
	{Pieces, crypto:hash(
		?MINING_HASH_ALG,
		<< Piece || Piece <- Pieces >>
	)}.

refresh_block_data_segment_timestamp(Pieces, PrecedingB, POA, TXs, RewardAddr, Time) ->
	NewHeight = PrecedingB#block.height + 1,
	Retarget =
		case ar_retarget:is_retarget_height(NewHeight) of
			true -> Time;
			false -> PrecedingB#block.last_retarget
		end,
	WeaveSize = PrecedingB#block.weave_size +
		lists:foldl(
			fun(TX, Acc) ->
				Acc + byte_size(TX#tx.data)
			end,
			0,
			TXs
		),
	NewDiff = ar_retarget:maybe_retarget(
		PrecedingB#block.height + 1,
		PrecedingB#block.diff,
		Time,
		PrecedingB#block.last_retarget
	),
	{FinderReward, RewardPool} =
		ar_node_utils:calculate_reward_pool(
			PrecedingB#block.reward_pool,
			TXs,
			RewardAddr,
			POA,
			WeaveSize,
			PrecedingB#block.height + 1,
			NewDiff,
			Time
		),
	NewWalletList =
		ar_node_utils:apply_mining_reward(
			ar_node_utils:apply_txs(PrecedingB#block.wallet_list, TXs, PrecedingB#block.height),
			RewardAddr,
			FinderReward,
			length(PrecedingB#block.hash_list) - 1
		),
	NewPieces = [
		lists:nth(1, Pieces),
		<<
			(integer_to_binary(Time))/binary,
			(integer_to_binary(Retarget))/binary
		>>,
		lists:nth(3, Pieces),
		<<
			(
				binary:list_to_bin(
					lists:map(
						fun ar_wallet:to_binary/1,
						NewWalletList
					)
				)
			)/binary
		>>,
		lists:nth(5, Pieces),
		<<
			(integer_to_binary(RewardPool))/binary
		>>,
		lists:nth(7, Pieces)
	],
	{NewPieces, crypto:hash(
		?MINING_HASH_ALG,
		<< Piece || Piece <- NewPieces >>
	)}.

%% @doc Verify the independant hash of a given block is valid
verify_indep_hash(Block = #block { indep_hash = Indep }) ->
	Indep == ar_weave:indep_hash(Block).

%% @doc Verify the dependent hash of a given block is valid
verify_dep_hash(NewB, BDSHash) ->
	NewB#block.hash == BDSHash.

verify_tx_root(B) ->
	B#block.tx_root == generate_tx_root_for_block(B).

%% @doc Given a list of TXs in various formats, or a block, generate the
%% correct TX merkle tree root.
generate_tx_root_for_block(B) when is_record(B, block) ->
	generate_tx_root_for_block(B#block.txs);
generate_tx_root_for_block(TXIDs = [TXID | _]) when is_binary(TXID) ->
	generate_tx_root_for_block(ar_storage:read_tx(TXIDs));
generate_tx_root_for_block(TXs = [TX | _]) when is_record(TX, tx) ->
	generate_tx_root_for_block([{T#tx.id, T#tx.data_size} || T <- TXs]);
generate_tx_root_for_block(TXSizes) ->
	TXSizePairs = generate_size_tagged_list_from_txs(TXSizes),
	{Root, _Tree} = ar_merkle:generate_tree(TXSizePairs),
	Root.

%% @doc Verify the block timestamp is not too far in the future nor too far in
%% the past. We calculate the maximum reasonable clock difference between any
%% two nodes. This is a simplification since there is a chaining effect in the
%% network which we don't take into account. Instead, we assume two nodes can
%% deviate JOIN_CLOCK_TOLERANCE seconds in the opposite direction from each
%% other.
verify_timestamp(B) ->
	CurrentTime = os:system_time(seconds),
	MaxNodesClockDeviation = ?JOIN_CLOCK_TOLERANCE * 2 + ?CLOCK_DRIFT_MAX,
	(
		B#block.timestamp =< CurrentTime + MaxNodesClockDeviation
		andalso
		B#block.timestamp >= CurrentTime - lists:sum([
			?MINING_TIMESTAMP_REFRESH_INTERVAL,
			?MAX_BLOCK_PROPAGATION_TIME,
			MaxNodesClockDeviation
		])
	).

%% @doc Verify the height of the new block is the one higher than the
%% current height.
verify_height(NewB, OldB) ->
	NewB#block.height == (OldB#block.height + 1).

%% @doc Verify the retarget timestamp on NewB is correct.
verify_last_retarget(NewB, OldB) ->
	case ar_retarget:is_retarget_height(NewB#block.height) of
		true ->
			NewB#block.last_retarget == NewB#block.timestamp;
		false ->
			NewB#block.last_retarget == OldB#block.last_retarget
	end.

%% @doc Verify that the previous_block hash of the new block is the indep_hash
%% of the current block.
verify_previous_block(NewB, OldB) ->
	OldB#block.indep_hash == NewB#block.previous_block.

%% @doc Verify that the new block's hash_list is the current block's
%% hash_list + indep_hash, until ?FORK_1_6.
verify_block_hash_list(NewB, OldB) when NewB#block.height < ?FORK_1_6 ->
	NewB#block.hash_list == [OldB#block.indep_hash | OldB#block.hash_list];
verify_block_hash_list(_NewB, _OldB) -> true.

%% @doc Verify that the new blocks wallet_list and reward_pool matches that
%% generated by applying, the block miner reward and mined TXs to the current
%% (old) blocks wallet_list and reward pool.
verify_wallet_list(NewB, OldB, POA, NewTXs) ->
	{FinderReward, RewardPool} =
		ar_node_utils:calculate_reward_pool(
			OldB#block.reward_pool,
			NewTXs,
			NewB#block.reward_addr,
			POA,
			NewB#block.weave_size,
			length(NewB#block.hash_list),
			NewB#block.diff,
			NewB#block.timestamp
		),
	RewardAddress = case OldB#block.reward_addr of
		unclaimed -> <<"unclaimed">>;
		_         -> ar_util:encode(OldB#block.reward_addr)
	end,
	ar:report(
		[
			verifying_finder_reward,
			{finder_reward, FinderReward},
			{new_reward_pool, RewardPool},
			{reward_address, RewardAddress},
			{old_reward_pool, OldB#block.reward_pool},
			{txs, length(NewTXs)},
			{weave_size, NewB#block.weave_size},
			{length, length(NewB#block.hash_list)}
		]
	),
	(NewB#block.reward_pool == RewardPool) and
	((NewB#block.wallet_list) ==
		ar_node_utils:apply_mining_reward(
			ar_node_utils:apply_txs(OldB#block.wallet_list, NewTXs, OldB#block.height),
			NewB#block.reward_addr,
			FinderReward,
			NewB#block.height
		)).

verify_weave_size(NewB, OldB, TXs) ->
	NewB#block.weave_size == lists:foldl(
		fun(TX, Acc) ->
			Acc + byte_size(TX#tx.data)
		end,
		OldB#block.weave_size,
		TXs
	).

%% @doc Ensure that after the 1.6 release cumulative difficulty is enforced.
verify_cumulative_diff(NewB, OldB) ->
	NewB#block.cumulative_diff ==
		ar_difficulty:next_cumulative_diff(
			OldB#block.cumulative_diff,
			NewB#block.diff,
			NewB#block.height
		).

%% @doc After 1.6 fork check that the given merkle root in a new block is valid.
verify_block_hash_list_merkle(NewB, CurrentB, BI) when NewB#block.height > ?FORK_1_6 ->
	Fork_2_0 = ar_fork:height_2_0(),
	case NewB#block.height of
		H when H < Fork_2_0 ->
			NewB#block.hash_list_merkle ==
				ar_unbalanced_merkle:root(CurrentB#block.hash_list_merkle, CurrentB#block.indep_hash);
		Fork_2_0 ->
			NewB#block.hash_list_merkle == ar_unbalanced_merkle:block_index_to_merkle_root(BI);
		_ ->
			NewB#block.hash_list_merkle ==
				ar_unbalanced_merkle:root(
					CurrentB#block.hash_list_merkle,
					{CurrentB#block.indep_hash, CurrentB#block.weave_size},
					fun ar_unbalanced_merkle:hash_block_index_entry/1
				)
	end;
verify_block_hash_list_merkle(NewB, _CurrentB, _) when NewB#block.height < ?FORK_1_6 ->
	NewB#block.hash_list_merkle == <<>>;
verify_block_hash_list_merkle(NewB, CurrentB, _) when NewB#block.height == ?FORK_1_6 ->
	NewB#block.hash_list_merkle == ar_unbalanced_merkle:hash_list_to_merkle_root(CurrentB#block.hash_list).

get_recall_block(OrigPeer, RecallHash, BI, Key, Nonce) ->
	case ar_storage:read_block(RecallHash, BI) of
		unavailable ->
			case ar_storage:read_encrypted_block(RecallHash) of
				unavailable ->
					ar:report([{downloading_recall_block, ar_util:encode(RecallHash)}]),
					FullBlock =
						ar_node_utils:get_full_block(OrigPeer, RecallHash, BI),
					case ?IS_BLOCK(FullBlock)  of
						true ->
							ar_storage:write_full_block(FullBlock),
							FullBlock#block {
								txs = [ T#tx.id || T <- FullBlock#block.txs]
							};
						false -> unavailable
					end;
				EncryptedRecall ->
					FBlock =
						decrypt_full_block(
							EncryptedRecall,
							Key,
							Nonce
						),
					case FBlock of
						unavailable -> unavailable;
						FullBlock ->
							ar_storage:write_full_block(FullBlock),
							FullBlock#block {
								txs = [ T#tx.id || T <- FullBlock#block.txs]
							}
					end
			end;
		Recall -> Recall
	end.

%% @doc Take a height, a list of preceding hashes
%% in the v2 format, and a list of preceding hashes
%% in the v1 format and join them in a single list
%% so that the hashes before the fork 2.0 are in the
%% v1 format and the hashes after the fork 2.0 are
%% in the v2 format.
join_v1_v2_hash_list(Height, V2HL, V1HL) ->
	Fork_2_0 = ar_fork:height_2_0(),
	case Height < Fork_2_0 of
		true ->
			V2HL;
		false ->
			SinceFork = Height - Fork_2_0,
			lists:sublist(V2HL, 1, SinceFork)
				++ lists:sublist(V1HL, 1, max(length(V2HL) - SinceFork, 0))
	end.

%% Tests: ar_block

hash_list_gen_test() ->
	ar_storage:clear(),
	B0s = [B0] = ar_weave:init([]),
	ar_storage:write_block(B0),
	B1s = [B1 | _] = ar_weave:add(B0s, []),
	ar_storage:write_block(B1),
	B2s = [B2 | _] = ar_weave:add(B1s, []),
	ar_storage:write_block(B2),
	[_ | BI] = ar_weave:add(B2s, []),
	HL1 = B1#block.hash_list,
	HL2 = B2#block.hash_list,
	HL1 = generate_hash_list_for_block(B1, BI),
	HL2 = generate_hash_list_for_block(B2#block.indep_hash, BI).

pad_unpad_roundtrip_test() ->
	Pad = pad_to_length(<<"abcdefghabcdefghabcd">>),
	UnPad = unpad_binary(Pad),
	Pad == UnPad.

join_v1_v2_hash_list_test_() ->
	ar_test_fork:test_on_fork(
		height_2_0,
		5,
		fun() ->
			%% Before 2.0.
			?assertEqual([h1, h2, h3, h4], join_v1_v2_hash_list(4, [h1, h2, h3, h4], [])),
			?assertEqual([h1, h2, h3, h4], join_v1_v2_hash_list(4, [h1, h2, h3, h4], [h11, h12, h13, h14])),
			%% After 2.0.
			?assertEqual([h1], join_v1_v2_hash_list(6, [h1], [])),
			?assertEqual([h1], join_v1_v2_hash_list(6, [h1], [h11])),
			?assertEqual([h1, h2], join_v1_v2_hash_list(7, [h1, h2], [])),
			?assertEqual([h1, h2], join_v1_v2_hash_list(7, [h1, h2], [h11, h12])),
			%% Before and after 2.0.
			?assertEqual([h11], join_v1_v2_hash_list(5, [h1], [h11])),
			?assertEqual([h1, h11, h12], join_v1_v2_hash_list(6, [h1, h2, h3], [h11, h12, h13]))
		end
	).
