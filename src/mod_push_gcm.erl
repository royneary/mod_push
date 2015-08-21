%%%----------------------------------------------------------------------
%%% File    : mod_push_gcm.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : Send push notifications to the Google Cloud Messaging service
%%% Created : 01 Jun 2015 by Christian Ulrich <christian@rechenwerk.net>
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

-module(mod_push_gcm).

-author('christian@rechenwerk.net').

-behaviour(gen_server).

-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

-define(PUSH_URL, "https://gcm-http.googleapis.com/gcm/send").
-define(EXPIRY_TIME, 60*60*24).
-define(HTTP_TIMEOUT, 10000).
-define(HTTP_CONNECT_TIMEOUT, 10000).
-define(RETRY_INTERVAL, 30000).
-define(MAX_PAYLOAD_SIZE, 4096).
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    H =/= sha, H =/= md5]).

-record(state,
        {certfile :: binary(),
         api_key :: binary(),
         retry_list :: [{atom(), any()}],
         retry_timer :: reference()}).

%-------------------------------------------------------------------------

init([AuthKey, _PackageSid, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_gcm:init", []),
    inets:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile,
                api_key = AuthKey,
                retry_list = [],
                retry_timer = make_ref()}}.

%-------------------------------------------------------------------------

handle_info(retry, #state{certfile = CertFile,
                          api_key = ApiKey,
                          retry_list = List,
                          retry_timer = Timer} = State) ->
    NewList =
    lists:filter(
        fun({_, Payload, Token, DisableArgs}) ->
            case send_request(Payload, Token, CertFile, ApiKey) of
                error ->
                    mod_push:unregister_client(DisableArgs),
                    false;

                ok -> false;

                retry -> true
            end
        end,
        List),
    NewTimer =
    case NewList of
        [] -> Timer;
        _ -> erlang:send_after(?RETRY_INTERVAL, self(), retry)
    end,
    {noreply, State#state{retry_list = NewList, retry_timer = NewTimer}};

handle_info(_Info, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_cast({dispatch, UserBare, Payload, Token, _AppId, DisableArgs},
            #state{certfile = CertFile, api_key = ApiKey} = State) ->
    ?DEBUG("+++++ Sending push notification to ~p", [?PUSH_URL]),
    NewState =
    case send_request(Payload, Token, CertFile, ApiKey) of
        error ->
            mod_push:unregister_client(DisableArgs),
            State;
        retry ->
            #state{retry_list = OldList, retry_timer = OldTimer} = State,
            NewTimer =
            case erlang:read_timer(OldTimer) of
                false -> erlang:send_after(?RETRY_INTERVAL, self(), retry);
                Timer -> Timer
            end,
            NewList =
            lists:keystore(UserBare, 1, OldList,
                           {UserBare, Payload, Token, DisableArgs}),
            State#state{retry_list = NewList, retry_timer = NewTimer};
        _ ->
            State
    end,
    {noreply, NewState};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, State) ->
    {noreply, State}.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------

send_request(Payload, Token, CertFile, ApiKey) ->
    P = case payload_size_ok(Payload) of
        true -> Payload;
        false -> []
    end,
    PushMessage =
    {struct,
    [{to, Token}, {time_to_live, ?EXPIRY_TIME}, {data, {struct, P}}]},
    ?DEBUG("+++++++ PushMessage (before encoding): ~p", [PushMessage]),
    Body = iolist_to_binary(mochijson2:encode(PushMessage)),
    ?DEBUG("+++++++ encoded json: ~s", [Body]),
    SslOpts =
    [{certfile, CertFile},
     {versions, ['tlsv1.2']},
     {ciphers, ?CIPHERSUITES},
     {reuse_sessions, true},
     {secure_renegotiate, true}],
     %{verify, verify_peer},
     %{cacertfile, CACertFile}],
    HttpOpts =
    [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT},
     {ssl, SslOpts}],
    Opts =
    [{full_result, false}],
    Authorization =
    "key=" ++ binary_to_list(ApiKey),
    Request =
    {?PUSH_URL, [{"Authorization", Authorization}], "application/json", Body},
    case
        httpc:request(post, Request, HttpOpts, Opts)
    of
        {ok, {200, ResponseBody}} ->
            ?DEBUG("+++++ raw response: StatusCode = ~p, Body = ~p",
                   [200, ResponseBody]),
            process_success_response(ResponseBody);

        {ok, {ErrorCode5xx, ErrorBody5xx}} when ErrorCode5xx >= 500,
                                                ErrorCode5xx < 600 ->
            ?INFO_MSG("recoverable GCM error: ~p, retrying...", [ErrorBody5xx]),
            retry;

        {ok, {_ErrorCode, ErrorBody}} ->
            ?INFO_MSG("non-recoverable GCM error: ~p, delete registration",
                      [ErrorBody]),
            error;

        {error, Reason} ->
            ?ERROR_MSG("GCM request failed: ~p, retrying...", [Reason]),
            retry
    end.

%-------------------------------------------------------------------------

process_success_response(ResponseBody) ->
    case mochijson2:decode(ResponseBody) of
        {struct, DecodedBody} when is_list(DecodedBody) ->
            ?DEBUG("+++++ Decoded body: ~p", [DecodedBody]),
            case proplists:get_value(<<"failure">>, DecodedBody) of
                0 ->
                    ?DEBUG("+++++ Success!", []),
                    ok;
    
                _ ->
                    case proplists:get_value(<<"results">>, DecodedBody) of
                        {struct, [ErrorBody|_]} ->
                            ErrorCondition =
                            proplists:get_value(<<"error">>, ErrorBody),
                            IsRecoverable =
                            lists:member(ErrorCondition,
                                         [<<"Unavailable">>,
                                          <<"InternalServerError">>]),
                            case IsRecoverable of
                                true ->
                                    ?INFO_MSG(
                                        "recoverable GCM error: ~p, retrying...",
                                        [ErrorCondition]),
                                    retry;
    
                                false ->
                                    ?INFO_MSG(
                                        "non-recoverable GCM error: ~p, "
                                        "delete Registration",
                                        [ErrorCondition]),
                                    error
                            end;
    
                        _ ->
                            ?ERROR_MSG(
                                "Invalid GCM response, treating as "
                                "non-recoverable error", []),
                            error
                    end
            end;
    
        _ -> ?ERROR_MSG("Invalid GCM response, treating as "
                        "non-recoverable error", []),
             error
    end.

%-------------------------------------------------------------------------

payload_size_ok(Payload) ->
    EncodedPayload = mochijson2:encode({struct, Payload}),
    iolist_size(EncodedPayload) =< ?MAX_PAYLOAD_SIZE.
