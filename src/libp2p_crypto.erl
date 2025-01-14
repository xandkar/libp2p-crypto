-module(libp2p_crypto).

-include_lib("public_key/include/public_key.hrl").

%% The binary key representation is a leading byte followed by the key material
%% (either public or private).
%%
%% In order to support different networks (e.g. mainnet and testnet)
%% the leading byte is split into two four bit parts.
%% The first nibble is the network the key is on (NETTTYPE), and the second
%% the type of keythat follows in the binary (KEYTYPE).
-define(KEYTYPE_ECC_COMPACT, 0).
-define(KEYTYPE_ED25519, 1).
-define(NETTYPE_MAIN, 0).
-define(NETTYPE_TEST, 1).

-type key_type() :: ecc_compact | ed25519.
-type network() :: mainnet | testnet.
-type privkey() ::
    {ecc_compact, ecc_compact:private_key()}
    | {ed25519, enacl_privkey()}.

-type pubkey() ::
    {ecc_compact, ecc_compact:public_key()}
    | {ed25519, enacl_pubkey()}.

-type pubkey_bin() :: <<_:8, _:_*8>>.
-type sig_fun() :: fun((binary()) -> binary()).
-type ecdh_fun() :: fun((pubkey()) -> binary()).
-type key_map() :: #{secret => privkey(), public => pubkey(), network => network()}.
-type enacl_privkey() :: <<_:256>>.
-type enacl_pubkey() :: <<_:256>>.

-export_type([privkey/0, pubkey/0, pubkey_bin/0, sig_fun/0, ecdh_fun/0]).

-export([
    get_network/1,
    set_network/1,
    generate_keys/1,
    generate_keys/2,
    mk_sig_fun/1,
    mk_ecdh_fun/1,
    load_keys/1,
    save_keys/2,
    pubkey_to_bin/1,
    pubkey_to_bin/2,
    bin_to_pubkey/1,
    bin_to_pubkey/2,
    bin_to_b58/1,
    bin_to_b58/2,
    b58_to_bin/1,
    b58_to_version_bin/1,
    pubkey_to_b58/1,
    pubkey_to_b58/2,
    b58_to_pubkey/1,
    b58_to_pubkey/2,
    pubkey_bin_to_p2p/1,
    p2p_to_pubkey_bin/1,
    verify/3,
    keys_to_bin/1,
    keys_from_bin/1
]).

-define(network, libp2p_crypto_network).

%% @doc Get the currrent network used for public and private keys.
%% If not set return the given default
-spec get_network(Default :: network()) -> network().
get_network(Default) ->
    persistent_term:get(?network, Default).

%% @doc Sets the network used for public and private keys.
-spec set_network(network()) -> ok.
set_network(Network) ->
    persistent_term:put(?network, Network).

%% @doc Generate keys suitable for a swarm.  The returned private and
%% public key has the attribute that the public key is a compressable
%% public key.
%%
%% The keys are generated on the currently active network.
-spec generate_keys(key_type()) -> key_map().
generate_keys(KeyType) ->
    generate_keys(get_network(mainnet), KeyType).

%% @doc Generate keys suitable for a swarm on a given network.
%% The returned private and public key has the attribute that
%% the public key is a compressable public key if ecc_compact is used.
-spec generate_keys(network(), key_type()) -> key_map().
generate_keys(Network, ecc_compact) ->
    {ok, PrivKey, CompactKey} = ecc_compact:generate_key(),
    PubKey = ecc_compact:recover_key(CompactKey),
    #{
        secret => {ecc_compact, PrivKey},
        public => {ecc_compact, PubKey},
        network => Network
    };
generate_keys(Network, ed25519) ->
    #{public := PubKey, secret := PrivKey} = enacl:crypto_sign_ed25519_keypair(),
    #{
        secret => {ed25519, PrivKey},
        public => {ed25519, PubKey},
        network => Network
    }.

%% @doc Load the private key from a pem encoded given filename.
%% Returns the private and extracted public key stored in the file or
%% an error if any occorred.
-spec load_keys(string()) -> {ok, key_map()} | {error, term()}.
load_keys(FileName) ->
    case file:read_file(FileName) of
        {ok, Bin} -> {ok, keys_from_bin(Bin)};
        {error, Error} -> {error, Error}
    end.

%% @doc Construct a signing function from a given private key. Using a
%% signature function instead of passing a private key around allows
%% different signing implementations, such as one built on a hardware
%% based security module.
-spec mk_sig_fun(privkey()) -> sig_fun().
mk_sig_fun({ecc_compact, PrivKey}) ->
    fun(Bin) -> public_key:sign(Bin, sha256, PrivKey) end;
mk_sig_fun({ed25519, PrivKey}) ->
    fun(Bin) -> enacl:sign_detached(Bin, PrivKey) end.

%% @doc Constructs an ECDH exchange function from a given private key.
%%
%% Note that a Key Derivation Function should be applied to these keys
%% before use
-spec mk_ecdh_fun(privkey()) -> ecdh_fun().
mk_ecdh_fun({ecc_compact, PrivKey}) ->
    fun({ecc_compact, {PubKey, {namedCurve, ?secp256r1}}}) ->
        public_key:compute_key(PubKey, PrivKey)
    end;
mk_ecdh_fun({ed25519, PrivKey}) ->
    %% Do an X25519 ECDH exchange after converting the ED25519 keys to Curve25519 keys
    fun({ed25519, PubKey}) ->
        enacl:box_beforenm(
            enacl:crypto_sign_ed25519_public_to_curve25519(PubKey),
            enacl:crypto_sign_ed25519_secret_to_curve25519(PrivKey)
        )
    end.

%% @doc Store the given keys in a given filename. The keypair is
%% converted to binary keys_to_bin
%%
%% @see keys_to_bin/1
-spec save_keys(key_map(), string()) -> ok | {error, term()}.
save_keys(KeysMap, FileName) when is_list(FileName) ->
    Bin = keys_to_bin(KeysMap),
    file:write_file(FileName, Bin).

%% @doc Convert a given key map to a binary representation that can be
%% saved to file.
-spec keys_to_bin(key_map()) -> binary().
keys_to_bin(Keys = #{secret := {ecc_compact, PrivKey}, public := {ecc_compact, _PubKey}}) ->
    #'ECPrivateKey'{privateKey = PrivKeyBin, publicKey = PubKeyBin} = PrivKey,
    NetType = from_network(maps:get(network, Keys, mainnet)),
    case byte_size(PrivKeyBin) of
        32 ->
            <<NetType:4, ?KEYTYPE_ECC_COMPACT:4, PrivKeyBin:32/binary, PubKeyBin/binary>>;
        31 ->
            %% sometimes a key is only 31 bytes
            <<NetType:4, ?KEYTYPE_ECC_COMPACT:4, 0:8/integer, PrivKeyBin:31/binary,
                PubKeyBin/binary>>
    end;
keys_to_bin(Keys = #{secret := {ed25519, PrivKey}, public := {ed25519, PubKey}}) ->
    NetType = from_network(maps:get(network, Keys, mainnet)),
    <<NetType:4, ?KEYTYPE_ED25519:4, PrivKey:64/binary, PubKey:32/binary>>.

%% @doc Convers a given binary to a key map
-spec keys_from_bin(binary()) -> key_map().
%% Support the Helium Rust wallet format, which unfortunately duplicates the network
%% and key type just before the public key.
keys_from_bin(
    <<NetType:4, ?KEYTYPE_ECC_COMPACT:4, PrivKey:32/binary, NetType:4, ?KEYTYPE_ECC_COMPACT:4,
        PubKey:32/binary>>
) ->
    {#'ECPoint'{point = PubKeyBin}, _} = ecc_compact:recover_key(PubKey),
    keys_from_bin(<<NetType:4, ?KEYTYPE_ECC_COMPACT:4, PrivKey/binary, PubKeyBin/binary>>);
keys_from_bin(
    <<NetType:4, ?KEYTYPE_ED25519:4, PrivKey:64/binary, NetType:4, ?KEYTYPE_ED25519:4,
        PubKey:32/binary>>
) ->
    keys_from_bin(<<NetType:4, ?KEYTYPE_ED25519:4, PrivKey/binary, PubKey/binary>>);
%% Followed by the convention uses in this library
keys_from_bin(
    <<NetType:4, ?KEYTYPE_ECC_COMPACT:4, 0:8/integer, PrivKeyBin:31/binary, PubKeyBin/binary>>
) ->
    Params = {namedCurve, ?secp256r1},
    PrivKey = #'ECPrivateKey'{
        version = 1,
        parameters = Params,
        privateKey = PrivKeyBin,
        publicKey = PubKeyBin
    },
    PubKey = {#'ECPoint'{point = PubKeyBin}, Params},
    #{
        secret => {ecc_compact, PrivKey},
        public => {ecc_compact, PubKey},
        network => to_network(NetType)
    };
keys_from_bin(
    <<NetType:4, ?KEYTYPE_ECC_COMPACT:4, PrivKeyBin:32/binary, PubKeyBin/binary>>
) ->
    Params = {namedCurve, ?secp256r1},
    PrivKey = #'ECPrivateKey'{
        version = 1,
        parameters = Params,
        privateKey = PrivKeyBin,
        publicKey = PubKeyBin
    },
    PubKey = {#'ECPoint'{point = PubKeyBin}, Params},
    #{
        secret => {ecc_compact, PrivKey},
        public => {ecc_compact, PubKey},
        network => to_network(NetType)
    };
keys_from_bin(<<NetType:4, ?KEYTYPE_ED25519:4, PrivKey:64/binary, PubKey:32/binary>>) ->
    #{
        secret => {ed25519, PrivKey},
        public => {ed25519, PubKey},
        network => to_network(NetType)
    }.

%% @doc Convertsa a given tagged public key to its binary form on the current
%% network.
-spec pubkey_to_bin(pubkey()) -> pubkey_bin().
pubkey_to_bin(PubKey) ->
    pubkey_to_bin(get_network(mainnet), PubKey).

%% @doc Convertsa a given tagged public key to its binary form on the given
%% network.
-spec pubkey_to_bin(network(), pubkey()) -> pubkey_bin().
pubkey_to_bin(Network, {ecc_compact, PubKey}) ->
    case ecc_compact:is_compact(PubKey) of
        {true, CompactKey} ->
            <<(from_network(Network)):4, ?KEYTYPE_ECC_COMPACT:4, CompactKey/binary>>;
        false ->
            erlang:error(not_compact)
    end;
pubkey_to_bin(Network, {ed25519, PubKey}) ->
    <<(from_network(Network)):4, ?KEYTYPE_ED25519:4, PubKey/binary>>.

%% @doc Convertsa a given binary encoded public key to a tagged public
%% key. The key is asserted to be on the current active network.
-spec bin_to_pubkey(pubkey_bin()) -> pubkey().
bin_to_pubkey(PubKeyBin) ->
    bin_to_pubkey(get_network(mainnet), PubKeyBin).

%% @doc Convertsa a given binary encoded public key to a tagged public key. If
%% the given binary is not on the specified network a bad_network is thrown.
-spec bin_to_pubkey(network(), pubkey_bin()) -> pubkey().
bin_to_pubkey(Network, <<NetType:4, ?KEYTYPE_ECC_COMPACT:4, PubKey:32/binary>>) ->
    case NetType == from_network(Network) of
        true -> {ecc_compact, ecc_compact:recover_key(PubKey)};
        false -> erlang:error({bad_network, NetType})
    end;
bin_to_pubkey(Network, <<NetType:4, ?KEYTYPE_ED25519:4, PubKey:32/binary>>) ->
    case NetType == from_network(Network) of
        true -> {ed25519, PubKey};
        false -> erlang:error({bad_network, NetType})
    end.

%% @doc Converts a public key to base58 check encoded string
%% on the currently active network.
-spec pubkey_to_b58(pubkey()) -> string().
pubkey_to_b58(PubKey) ->
    pubkey_to_b58(get_network(mainnet), PubKey).

%% @doc Converts a public key to base58 check encoded string on the given
%% network.
-spec pubkey_to_b58(network(), pubkey()) -> string().
pubkey_to_b58(Network, PubKey) ->
    bin_to_b58(pubkey_to_bin(Network, PubKey)).

%% @doc Converts a base58 check encoded string to a public key.
%% The public key is asserted to be on the currently active network.
-spec b58_to_pubkey(string()) -> pubkey().
b58_to_pubkey(Str) ->
    b58_to_pubkey(get_network(mainnet), Str).

%% @doc Converts a base58 check encoded string to a public key.
%% The public key is asserted to be on the given network.
-spec b58_to_pubkey(network(), string()) -> pubkey().
b58_to_pubkey(Network, Str) ->
    bin_to_pubkey(Network, b58_to_bin(Str)).

%% @doc Convert mainnet or testnet to its tag nibble
-spec from_network(network()) -> ?NETTYPE_MAIN | ?NETTYPE_TEST.
from_network(mainnet) -> ?NETTYPE_MAIN;
from_network(testnet) -> ?NETTYPE_TEST.

%% @doc Convert a testnet nibble to mainnet or testnet.
-spec to_network(?NETTYPE_MAIN | ?NETTYPE_TEST) -> network().
to_network(?NETTYPE_MAIN) -> mainnet;
to_network(?NETTYPE_TEST) -> testnet.

%% @doc Verifies a binary against a given digital signature over the
%% sha256 of the binary.
-spec verify(binary(), binary(), pubkey()) -> boolean().
verify(Bin, Signature, {ecc_compact, PubKey}) ->
    public_key:verify(Bin, sha256, Signature, PubKey);
verify(Bin, Signature, {ed25519, PubKey}) ->
    enacl:sign_verify_detached(Signature, Bin, PubKey).

%% @doc Convert a binary to a base58 check encoded string. The encoded
%% version is set to 0.
%%
%% @see bin_to_b58/2
-spec bin_to_b58(binary()) -> string().
bin_to_b58(Bin) ->
    bin_to_b58(16#00, Bin).

%% @doc Convert a binary to a base58 check encoded string
-spec bin_to_b58(non_neg_integer(), binary()) -> string().
bin_to_b58(Version, Bin) ->
    base58check_encode(Version, Bin).

%% @doc Convert a base58 check encoded string to the original
%% binary.The version encoded in the base58 encoded string is ignore.
%%
%% @see b58_to_version_bin/1
-spec b58_to_bin(string()) -> binary().
b58_to_bin(Str) ->
    {_, Addr} = b58_to_version_bin(Str),
    Addr.

%% @doc Decodes a base58 check ecnoded string into it's version and
%% binary parts.
-spec b58_to_version_bin(string()) -> {Version :: non_neg_integer(), Bin :: binary()}.
b58_to_version_bin(Str) ->
    case base58check_decode(Str) of
        {ok, <<Version:8/unsigned-integer>>, Bin} -> {Version, Bin};
        {error, Reason} -> error(Reason)
    end.

%% @doc Converts a given binary public key to a P2P address.
%%
%% @see p2p_to_pubkey_bin/1
-spec pubkey_bin_to_p2p(pubkey_bin()) -> string().
pubkey_bin_to_p2p(PubKey) when is_binary(PubKey) ->
    "/p2p/" ++ bin_to_b58(PubKey).

%% @doc Takes a P2P address and decodes it to a binary public key
-spec p2p_to_pubkey_bin(string()) -> pubkey_bin().
p2p_to_pubkey_bin(Str) ->
    case multiaddr:protocols(Str) of
        [{"p2p", B58Addr}] -> b58_to_bin(B58Addr);
        _ -> error(badarg)
    end.

-spec base58check_encode(non_neg_integer(), binary()) -> string().
base58check_encode(Version, Payload) when Version >= 0, Version =< 16#FF ->
    VPayload = <<Version:8/unsigned-integer, Payload/binary>>,
    <<Checksum:4/binary, _/binary>> = crypto:hash(sha256, crypto:hash(sha256, VPayload)),
    Result = <<VPayload/binary, Checksum/binary>>,
    base58:binary_to_base58(Result).

-spec base58check_decode(string()) -> {'ok', <<_:8>>, binary()} | {error, bad_checksum}.
base58check_decode(B58) ->
    Bin = base58:base58_to_binary(B58),
    PayloadSize = byte_size(Bin) - 5,
    <<Version:1/binary, Payload:PayloadSize/binary, Checksum:4/binary>> = Bin,
    %% validate the checksum
    case crypto:hash(sha256, crypto:hash(sha256, <<Version/binary, Payload/binary>>)) of
        <<Checksum:4/binary, _/binary>> ->
            {ok, Version, Payload};
        _ ->
            {error, bad_checksum}
    end.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

save_load_test() ->
    SaveLoad = fun(Network, KeyType) ->
        FileName = nonl(os:cmd("mktemp")),
        Keys = generate_keys(Network, KeyType),
        ok = libp2p_crypto:save_keys(Keys, FileName),
        {ok, LKeys} = load_keys(FileName),
        ?assertEqual(LKeys, Keys)
    end,
    SaveLoad(mainnet, ecc_compact),
    SaveLoad(testnet, ecc_compact),
    SaveLoad(mainnet, ed25519),
    SaveLoad(testnet, ed25519),

    {error, _} = load_keys("no_such_file"),
    ok.

address_test() ->
    Roundtrip = fun(KeyType) ->
        #{public := PubKey} = generate_keys(KeyType),

        PubBin = pubkey_to_bin(PubKey),
        ?assertEqual(PubKey, bin_to_pubkey(PubBin)),

        PubB58 = bin_to_b58(PubBin),

        MAddr = pubkey_bin_to_p2p(PubBin),
        ?assertEqual(PubBin, p2p_to_pubkey_bin(MAddr)),

        ?assertEqual(PubB58, pubkey_to_b58(PubKey)),
        ?assertEqual(PubKey, b58_to_pubkey(PubB58)),

        BadNetwork =
            case get_network(mainnet) of
                mainnet -> testnet;
                testnet -> mainnet
            end,
        ?assertError({bad_network, _}, bin_to_pubkey(BadNetwork, PubBin))
    end,

    Roundtrip(ecc_compact),
    Roundtrip(ed25519),

    set_network(mainnet),
    Roundtrip(ecc_compact),
    Roundtrip(ed25519),

    set_network(testnet),
    Roundtrip(ecc_compact),
    Roundtrip(ed25519),

    ok.

verify_sign_test() ->
    Bin = <<"sign me please">>,
    Verify = fun(KeyType) ->
        #{secret := PrivKey, public := PubKey} = generate_keys(KeyType),
        Sign = mk_sig_fun(PrivKey),
        Signature = Sign(Bin),

        ?assert(verify(Bin, Signature, PubKey)),
        ?assert(not verify(<<"failed...">>, Signature, PubKey))
    end,

    Verify(ecc_compact),
    Verify(ed25519),

    ok.

verify_ecdh_test() ->
    Verify = fun(KeyType) ->
        #{secret := PrivKey1, public := PubKey1} = generate_keys(KeyType),
        #{secret := PrivKey2, public := PubKey2} = generate_keys(KeyType),
        #{secret := _PrivKey3, public := PubKey3} = generate_keys(KeyType),
        ECDH1 = mk_ecdh_fun(PrivKey1),
        ECDH2 = mk_ecdh_fun(PrivKey2),

        ?assertEqual(ECDH1(PubKey2), ECDH2(PubKey1)),
        ?assertNotEqual(ECDH1(PubKey3), ECDH2(PubKey3))
    end,

    Verify(ecc_compact),
    Verify(ed25519),

    ok.

%% erlfmt-ignore
round_trip_short_key_test() ->
    ShortKeyMap = #{
        network => mainnet,
        public =>
            {ecc_compact,
                {{'ECPoint',
                        <<4, 2, 151, 174, 89, 188, 129, 160, 76, 74, 234, 246, 22, 24, 16,
                            96, 70, 219, 183, 246, 235, 40, 90, 107, 29, 126, 74, 14, 11,
                            201, 75, 2, 168, 74, 18, 165, 99, 26, 32, 161, 195, 100, 232,
                            40, 130, 76, 231, 85, 239, 255, 213, 129, 210, 184, 181, 233,
                            79, 154, 11, 229, 103, 160, 213, 105, 208>>},
                    {namedCurve, {1, 2, 840, 10045, 3, 1, 7}}}},
        secret =>
            {ecc_compact,
                {'ECPrivateKey', 1,
                    <<49, 94, 129, 63, 91, 89, 3, 86, 29, 23, 158, 86, 76, 180, 129, 140,
                        194, 25, 52, 94, 141, 36, 222, 112, 234, 227, 33, 172, 94, 168,
                        123>>,
                    {namedCurve, {1, 2, 840, 10045, 3, 1, 7}},
                    <<4, 2, 151, 174, 89, 188, 129, 160, 76, 74, 234, 246, 22, 24, 16, 96,
                        70, 219, 183, 246, 235, 40, 90, 107, 29, 126, 74, 14, 11, 201, 75,
                        2, 168, 74, 18, 165, 99, 26, 32, 161, 195, 100, 232, 40, 130, 76,
                        231, 85, 239, 255, 213, 129, 210, 184, 181, 233, 79, 154, 11, 229,
                        103, 160, 213, 105, 208>>}}
    },
    Bin = keys_to_bin(ShortKeyMap),
    ?assertEqual(ShortKeyMap, keys_from_bin(Bin)),
    ok.

%% erlfmt-ignore
helium_wallet_decode_ed25519_test() ->
    FakeTestnetKeyMap = #{
        secret => {ed25519, <<192, 147, 19, 139, 114, 76, 92, 18, 67, 206, 210, 241, 21,
            18, 84, 12, 26, 171, 160, 255, 6, 17, 227, 18, 78, 255, 182, 94, 202, 62, 125,
            50, 75, 192, 49, 183, 242, 203, 231, 180, 84, 235, 178, 8, 57, 34, 132, 195,
            107, 140, 155, 85, 133, 58, 131, 188, 94, 234, 216, 101, 241, 12, 231, 107>>},
        public => {ed25519, <<87, 246, 67, 78, 245, 59, 166, 216, 236, 17, 195, 144, 101,
            96, 188, 112, 178, 183, 80, 75, 195, 218, 46, 184, 175, 181, 131, 207, 236,
            146, 18, 237>>},
        network => testnet
    },
    FakeTestnetKeyPair = <<
        %% Network/type byte (testnet, EDD25519)
         17,
        %% 64-byte private key
        192, 147,  19, 139, 114,  76,  92,  18,  67, 206, 210, 241,  21,  18,  84,  12,
         26, 171, 160, 255,   6,  17, 227,  18,  78, 255, 182,  94, 202,  62, 125,  50,
         75, 192,  49, 183, 242, 203, 231, 180,  84, 235, 178,   8,  57,  34, 132, 195,
        107, 140, 155,  85, 133,  58, 131, 188,  94, 234, 216, 101, 241,  12, 231, 107,
        %% Repeated network/type byte
         17,
        %% 32-byte public key
         87, 246,  67,  78, 245,  59, 166, 216, 236,  17, 195, 144, 101,  96, 188, 112,
        178, 183,  80,  75, 195, 218,  46, 184, 175, 181, 131, 207, 236, 146,  18, 237
    >>,
    KeyMap = keys_from_bin(FakeTestnetKeyPair),
    ?assertEqual(FakeTestnetKeyMap, KeyMap),
    ok.

%% erlfmt-ignore
helium_wallet_decode_ecc_compact_test() ->
    FakeTestnetKeyMap = #{
        network => testnet,
        public =>
            {ecc_compact,{{'ECPoint',
                <<4,35,41,75,130,51,74,141,42, 34,140,61,222,93,12,114,10,
                238,142,214,23,56,70,82,128, 107,100,190,75,80,92,66,106,
                47,99,220,162,215,185,130,211, 86,56,165,149,80,98,123,196,
                188,218,249,171,170,182,108, 247,184,233,199,14,216,41,209,
                36>>},
            {namedCurve,{1,2,840,10045,3,1,7}}}},
      secret =>
          {ecc_compact,{'ECPrivateKey',1,
                <<87,144,91,38,220,189,67,111,253,122,45,167,249,160,253,
                73,145,93,208,112,65,69,89,175,98,89,59,222,68,178,37,
                176>>,
            {namedCurve,{1,2,840,10045,3,1,7}},
                <<4,35,41,75,130,51,74,141,42,34,140,61,222,93,12,114,
                10,238,142,214,23,56,70,82,128,107,100,190,75,80,92,
                66,106,47,99,220,162,215,185,130,211,86,56,165,149,
                80,98,123,196,188,218,249,171,170,182,108,247,184,
                233,199,14,216,41,209,36>>}}},
    FakeTestnetKeyPair =
        <<
        %% network type byte (testnet, ecc_compact)
        16,
        %% 32 byte private key
        87,144,91,38,220,189,67,111,253,122,45,167,249,160,
        253,73,145,93,208,112,65,69,89,175,98,89,59,222,68,178,
        37,176,

        %% repeated type byte
        16,
        %% 32 byte compact public key
        35,41,75,130,51,74,141,42,34,140,61,222,93,12,
        114,10,238,142,214,23,56,70,82,128,107,100,190,75,80,92,
        66,106
        >>,
    KeyMap = keys_from_bin(FakeTestnetKeyPair),
    ?assertEqual(FakeTestnetKeyMap, KeyMap),
    ok.

nonl([$\n | T]) -> nonl(T);
nonl([H | T]) -> [H | nonl(T)];
nonl([]) -> [].

-endif.
