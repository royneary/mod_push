%%%----------------------------------------------------------------------
%%% File    : mod_push_mozilla.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : Send push notifications to the Ubuntu Push service
%%% Created : 07 June 2015 by Christian Ulrich <christian@rechenwerk.net>
%%%
%%%
%%% Copyright (C) 2015  Christian Ulrich
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

-module(mod_push_mozilla).

-author('christian@rechenwerk.net').

-behaviour(gen_server).

-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

-define(PUSH_URL, "https://updates.push.services.mozilla.com/push/").
-define(HTTP_TIMEOUT, 10000).
-define(HTTP_CONNECT_TIMEOUT, 10000).
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    H =/= sha, H =/= md5]).
-define(MAX_INT, 4294967295).

% TODO: add message_queue
-record(state,
        {certfile :: binary(),
         version = 0 :: pos_integer()}).

%-------------------------------------------------------------------------

init([_Host, _AuthKey, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_mozilla:init", []),
    inets:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile}}.

%-------------------------------------------------------------------------

handle_info(_Info, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_cast({dispatch, Payload, Token, _AppId, _Silent, DisableArgs},
            #state{certfile = CertFile,
                   version = Version} = State) ->
    Url = ?PUSH_URL ++ binary_to_list(Token),
    NewVersion = case Version of
        ?MAX_INT -> 0;
        V when is_integer(V) -> V + 1
    end,
    %% We're sending a data payload (json-encoded, then url-encoded) although
    %% that's not implemented yet (as of 2015-06-07) in Firefox OS. A client app
    %% only can access the version-field. The server (autopush v1.2.2) accepts
    %% it though
    Data = iolist_to_binary(mochijson2:encode({struct, Payload})),
    ?DEBUG("+++++ Sending push notification to ~p", [Url]),
    Body = url_encode([{<<"version">>, integer_to_binary(NewVersion)}, {<<"data">>, Data}]),
    SslOpts =
    [{certfile, CertFile}, {versions, ['tlsv1.2']}, {ciphers, ?CIPHERSUITES},
     {server_name_indication, disable}, {reuse_sessions, true}],
    HttpOpts =
    [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT},
     {ssl, SslOpts}],
    Opts =
    [],
    Request = {Url, [], "application/x-www-form-urlencoded", Body},
    Reply =
    try httpc:request(put, Request, HttpOpts, Opts) of
        {ok, {{_,200,_},_,RespBody}} ->
                    {ok, RespBody};
        {ok, {{_,202,_},_,RespBody}} ->
                    {retained, RespBody};
        Other -> Other
    catch
        Throw -> {error, caught, Throw}
    end,
    ?DEBUG("++++++++ Server replied: ~p", [Reply]),

    %DisableCb(),
    {noreply, State#state{version = NewVersion}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, State) -> {noreply, State}.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------

escape_uri(<<C:8, Cs/binary>>) when C >= $a, C =< $z ->
        [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $A, C =< $Z ->
        [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C >= $0, C =< $9 ->
        [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $. ->
        [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $- ->
        [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) when C == $_ ->
        [C] ++ escape_uri(Cs);
escape_uri(<<C:8, Cs/binary>>) ->
        escape_byte(C) ++ escape_uri(Cs);
escape_uri(<<>>) ->
        "".

escape_byte(C) ->
        "%" ++ hex_octet(C).

hex_octet(N) when N =< 9 ->
        [$0 + N];
hex_octet(N) when N > 15 ->
        hex_octet(N bsr 4) ++ hex_octet(N band 15);
hex_octet(N) ->
        [N - 10 + $a].


url_encode(Data) ->
        url_encode(Data,"").

url_encode([],Acc) ->
        Acc;
url_encode([{Key,Value}|R],"") ->
        url_encode(R, escape_uri(Key) ++ "=" ++ escape_uri(Value));
url_encode([{Key,Value}|R],Acc) ->
        url_encode(R, Acc ++ "&" ++ escape_uri(Key) ++ "=" ++ escape_uri(Value)).
