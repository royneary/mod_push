%%%----------------------------------------------------------------------
%%% File    : mod_push_apns.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : Send push notifications to the Apple Push Notification Service
%%% Created : 07 Feb 2015 by Christian Ulrich <christian@rechenwerk.net>
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

-module(mod_push_apns).

-author('christian@rechenwerk.net').

-behaviour(gen_server).

-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

%-define(PUSH_URL, "gateway.push.apple.com").
-define(PUSH_URL, "gateway.sandbox.push.apple.com").
-define(APNS_PORT, 2195).
-define(SSL_TIMEOUT, 10000).
-define(MESSAGE_EXPIRY_TIME, 86400).
-define(MESSAGE_PRIORITY, 10).
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    H =/= sha, H =/= md5]).

% TODO: add message_queue
-record(state,
        {certfile :: binary(),
         out_socket :: ssl:socket()}).

%-------------------------------------------------------------------------

init([_AuthKey, _PackageSid, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_apns:init", []),
    %inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile}}.

%-------------------------------------------------------------------------

handle_info({ssl, Socket, Data}, State) ->
    <<Command:8, Status:8, Id:32/big>> = iolist_to_binary(Data),
    ?INFO_MSG("received error reply from APNS: ~p / ~p / ~p",
              [Command, Status, Id]),
    ssl:close(Socket),
    {noreply, State#state{out_socket = undefined}};

handle_info({ssl_closed, _SslSocket}, State) ->
    ?INFO_MSG("connection to APNS closed!", []),
    {noreply, State#state{out_socket = undefined}};

handle_info(Info, State) ->
    ?DEBUG("+++++++ mod_push_apns received unexpected signal ~p", [Info]),
    {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) -> {noreply, State}.

%-------------------------------------------------------------------------

%% TODO: store {MessageId, DisableCb} tuples and handle invalid-token
%% error messages
handle_cast({dispatch, _UserBare, Payload, Token, _AppId, DisableArgs},
            #state{certfile = CertFile, out_socket = OutSocket} = State) ->
    ?DEBUG("+++++ Sending push notification to ~p", [?PUSH_URL]),
    Socket = case OutSocket of
        undefined ->
            ?DEBUG("++++++ no connection found, connecting...", []),
            SslOpts =
            [{certfile, CertFile}, {versions, ['tlsv1.2']}, {ciphers, ?CIPHERSUITES}],
            case ssl:connect(?PUSH_URL, ?APNS_PORT, SslOpts, ?SSL_TIMEOUT) of
                {ok, S} -> S;
                {error, E} -> {error, E}
            end;

        _ -> OutSocket
    end,
    PushMessage =
    {struct,
     [{aps, {struct, [{'content-available', 1}|Payload]}}]},
    EncodedMessage =
    iolist_to_binary(mochijson2:encode(PushMessage)),
    ?DEBUG("++++++ Encoded message: ~p", [EncodedMessage]),
    MessageLength = size(EncodedMessage),
    MessageId = randoms:get_string(),
    TokenLength = size(Token),
    ?DEBUG("Token: ~p, TokenLength: ~p", [Token, TokenLength]),
    case Socket of
        {error, Reason} ->
            ?INFO_MSG("Could not connect to APNS: ~p", [Reason]),
            {noreply, State#state{out_socket = undefined}};

        _ ->
            %% FIXME: MessageLength field has variable length, its value must be < 2K
            Frame =
             <<1:8, TokenLength:16/big, Token/binary,
               2:8, MessageLength:16/big, EncodedMessage/binary>>,
               %3:8, 4:16/big, MessageId/binary,
               %4:8, 4:16/big, ?MESSAGE_EXPIRY_TIME:4/big-unsigned-integer-unit:8,
               %5:8, 1:16/big, ?MESSAGE_PRIORITY:8>>,
            FrameLength = size(Frame),
            Packet =
            <<2:8, FrameLength:32/big, Frame/binary>>,
            ?DEBUG("++++++ Packet: ~p", [Packet]),
            SendResult = ssl:send(Socket, Packet),
            ?DEBUG("+++++ ssl:send returned ~p", [SendResult]),
            {noreply, State#state{out_socket = Socket}}
    end;

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, #state{out_socket = OutSocket}) ->
    case OutSocket of
        undefined -> ok;
        _ -> ssl:close(OutSocket)
    end.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------
