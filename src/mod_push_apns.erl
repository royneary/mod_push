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
-define(SSL_TIMEOUT, 3000).
-define(MAX_PAYLOAD_SIZE, 2048).
-define(MESSAGE_EXPIRY_TIME, 86400).
-define(MESSAGE_PRIORITY, 10).
-define(MAX_PENDING_NOTIFICATIONS, 16).
-define(PENDING_INTERVAL, 3000).
-define(RETRY_INTERVAL, 30000).
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    %K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    %H =/= sha, H =/= md5]).
                    H =/= md5]).

-record(state,
        {certfile :: binary(),
         out_socket :: ssl:socket(),
         pending_list :: [{pos_integer(), any()}],
         send_list :: [any()],
         retry_list :: [any()],
         pending_timer :: reference(),
         retry_timer :: reference(),
         pending_timestamp :: erlang:timestamp(),
         message_id :: pos_integer()}).

%-------------------------------------------------------------------------

init([_AuthKey, _PackageSid, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_apns:init, certfile = ~p", [CertFile]),
    inets:start(),
    crypto:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile,
                pending_list = [],
                send_list = [],
                retry_list = [],
                pending_timer = make_ref(),
                retry_timer = make_ref(),
                message_id = 0}}.

%-------------------------------------------------------------------------

%% error_received
handle_info({ssl, _Socket, Data},
            #state{pending_list = PendingList,
                   retry_list = RetryList,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    erlang:cancel_timer(PendingTimer),
    NewState =
    try
        <<RCommand:1/unit:8, RStatus:1/unit:8, RId:4/unit:8>> =
        iolist_to_binary(Data),
        {RCommand, RStatus, RId}
    of
        {8, Status, Id} ->
            case lists:keytake(Id, 1, PendingList) of
                false -> State;
                {value,
                 {_, {UserB, _, Token, DisableArgs} = Element}, NewPending} ->
                    case Status of
                        10 ->
                            ?INFO_MSG("recoverable APNS error, retrying...", []),
                            erlang:cancel_timer(RetryTimer),
                            NewRetryTimer =
                            erlang:send_after(?RETRY_INTERVAL, self(), retry),
                            State#state{pending_list = NewPending,
                                        retry_list = [Element|RetryList],
                                        retry_timer = NewRetryTimer};

                        7 ->
                            ?INFO_MSG("recoverable APNS error, retrying...", []),
                            erlang:cancel_timer(RetryTimer),
                            NewRetryTimer =
                            erlang:send_after(?RETRY_INTERVAL, self(), retry),
                            State#state{
                                pending_list = NewPending,
                                retry_list =
                                [{UserB, [], Token, DisableArgs}|RetryList],
                                retry_timer = NewRetryTimer};

                        S ->
                            ?INFO_MSG("non-recoverable APNS error: ~p", [S]),
                            mod_push:unregister_client(DisableArgs),
                            State#state{pending_list = NewPending}
                    end
            end;

        _ ->
            ?ERROR_MSG("invalid APNS response", []),
            State
    catch {'EXIT', _} ->
        ?ERROR_MSG("invalud APNS response", []),
        State
    end,
    self() ! send,
    {noreply, NewState#state{pending_timestamp = undefined}};
         
handle_info({ssl_closed, _SslSocket}, State) ->
    ?INFO_MSG("connection to APNS closed!", []),
    {noreply, State#state{out_socket = undefined}};

%% retry_timeout
handle_info(retry, #state{send_list = SendList,
                          retry_list = RetryList,
                          pending_timer = PendingTimer} = State) ->
    NewSendList = SendList ++ RetryList,
    case erlang:read_timer(PendingTimer) of
        false -> self() ! send;
        _ -> ok
    end,
    {noreply, State#state{send_list = NewSendList, retry_list = []}};

%% pending_timeout
handle_info({pending_timeout, Timestamp},
            #state{pending_timestamp = StoredTimestamp} = State) ->
    NewState =
    case Timestamp of
        StoredTimestamp ->
            self() ! send,
            State#state{pending_list = []};

        _ -> State
    end,
    {noreply, NewState};

handle_info(send, #state{certfile = CertFile,
                         out_socket = OldSocket,
                         pending_list = PendingList,
                         send_list = SendList,
                         retry_list = RetryList,
                         retry_timer = RetryTimer,
                         message_id = MessageId} = State) ->
    NewState =
    case get_socket(OldSocket, CertFile) of
        {error, Reason} ->
            ?ERROR_MSG("connection to APNS failed: ~p", [Reason]),
            NewRetryList =        
            pending_to_retry(PendingList, RetryList),
            erlang:cancel_timer(RetryTimer),
            NewRetryTimer =
            erlang:send_after(?RETRY_INTERVAL, self(), retry),
            State#state{out_socket = error,
                        pending_list = [],
                        retry_list = NewRetryList,
                        retry_timer = NewRetryTimer};

        Socket ->
            PendingSpace = ?MAX_PENDING_NOTIFICATIONS - length(PendingList),
            {NewPendingElements, NewSendList} =
            case length(SendList) > PendingSpace of
                true -> lists:split(PendingSpace, SendList);
                false -> {SendList, []}
            end,
            MakeMessageId =
            fun 
                (Max) when Max =:= (4294967296 - 1) -> 0;
                (OldMessageId) -> OldMessageId + 1
            end,
            {NewMessageId, Result} =
            lists:foldl(
                fun(Element, {MessageIdAcc, PendingListAcc}) ->
                    NewId = MakeMessageId(MessageIdAcc),
                    {NewId, [{NewId, Element}|PendingListAcc]}
                end,
                {MessageId, []},
                NewPendingElements),
            NewPendingList = PendingList ++ Result,
            case NewPendingList of
                [] ->
                    State#state{pending_list = NewPendingList,
                                send_list = NewSendList,
                                message_id = NewMessageId};

                _ ->
                    Notifications =
                    make_notifications(NewPendingList),
                    case ssl:send(Socket, Notifications) of
                        {error, Reason} ->
                            ?ERROR_MSG("sending to APNS failed: ~p",
                                       [Reason]),
                            NewRetryList =
                            pending_to_retry(NewPendingList, RetryList),
                            erlang:cancel_timer(RetryTimer),
                            NewRetryTimer =
                            erlang:send_after(?RETRY_INTERVAL, self(), retry),
                            State#state{out_socket = error,
                                        pending_list = [],
                                        retry_list = NewRetryList,
                                        send_list = NewSendList,
                                        retry_timer = NewRetryTimer,
                                        message_id = NewMessageId};

                        ok ->
                            ?INFO_MSG("sending to APNS successful", []),
                            Timestamp = erlang:now(),
                            NewPendingTimer =
                            erlang:send_after(?PENDING_INTERVAL, self(),
                                              {pending_timeout, Timestamp}),
                            State#state{out_socket = Socket,
                                        pending_list = NewPendingList,
                                        send_list = NewSendList,
                                        pending_timer = NewPendingTimer,
                                        message_id = NewMessageId,
                                        pending_timestamp = Timestamp}
                    end
            end
    end,
    {noreply, NewState};

handle_info(Info, State) ->
    ?DEBUG("+++++++ mod_push_apns received unexpected signal ~p", [Info]),
    {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

%% new message
handle_cast({dispatch, UserBare, Payload, Token, _AppId, DisableArgs},
            #state{send_list = SendList,
                   pending_timer = PendingTimer,
                   retry_timer = RetryTimer} = State) ->
    ?DEBUG("+++++ Sending push notification to ~p", [?PUSH_URL]),
    NewSendList =
    lists:keystore(UserBare, 1, SendList,
                   {UserBare, Payload, Token, DisableArgs}),
    case {erlang:read_timer(PendingTimer), erlang:read_timer(RetryTimer)} of
        {false, false} -> self() ! send;
        _ -> ok
    end,
    {noreply, State#state{send_list = NewSendList}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, #state{out_socket = OutSocket}) ->
    case OutSocket of
        undefined -> ok;
        error -> ok;
        _ -> ssl:close(OutSocket)
    end,
    ok.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------

make_notifications(PendingList) ->
    lists:foldl(
        fun({MessageId, {_, Payload, Token, _}}, Acc) ->
            PushMessage =
            {struct,
             [{aps, {struct, [{'content-available', 1}|Payload]}}]},
            EncodedMessage =
            iolist_to_binary(mochijson2:encode(PushMessage)),
            ?DEBUG("++++++ Encoded message: ~p", [EncodedMessage]),
            MessageLength = size(EncodedMessage),
            TokenLength = size(Token),
            ?DEBUG("Token: ~p, TokenLength: ~p", [Token, TokenLength]),
            Frame =
             <<1:1/unit:8, TokenLength:2/unit:8, Token/binary,
               2:1/unit:8, MessageLength:2/unit:8, EncodedMessage/binary,
               3:1/unit:8, 4:2/unit:8, MessageId:4/unit:8>>,
               %4:8, 4:16/big, ?MESSAGE_EXPIRY_TIME:4/big-unsigned-integer-unit:8,
               %5:8, 1:16/big, ?MESSAGE_PRIORITY:8>>,
            FrameLength = size(Frame),
            <<<<2:1/unit:8, FrameLength:4/unit:8, Frame/binary>>/binary, Acc/binary>>
        end,
        <<"">>,
        PendingList).

%-------------------------------------------------------------------------

get_socket(OldSocket, CertFile) ->
    case OldSocket of
        _Invalid when OldSocket =:= undefined;
                     OldSocket =:= error ->
            SslOpts =
            [{certfile, CertFile},
             {versions, ['tlsv1.2']},
             {ciphers, ?CIPHERSUITES},
             {reuse_sessions, true},
             {secure_renegotiate, true}],
             %{verify, verify_peer},
             %{cacertfile, CACertFile}],
            case ssl:connect(?PUSH_URL, ?APNS_PORT, SslOpts, ?SSL_TIMEOUT) of
                {ok, S} -> S;
                {error, E} -> {error, E}
            end;

       _ -> OldSocket
    end.

%-------------------------------------------------------------------------

pending_to_retry(PendingList, RetryList) ->
    %% FIXME: keystore
    RetryList ++
    lists:map(
        fun({_, Element}) -> Element end,
        PendingList).

%-------------------------------------------------------------------------
