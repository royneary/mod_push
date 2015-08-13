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
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    H =/= sha, H =/= md5]).

-record(state,
        {certfile :: binary(),
         api_key :: binary()}).

%-------------------------------------------------------------------------

init([_Host, AuthKey, _PackageSid, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_gcm:init", []),
    inets:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile, api_key = AuthKey}}.

%-------------------------------------------------------------------------

handle_info(_Info, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_cast({dispatch, Payload, Token, _AppId, DisableArgs},
            #state{certfile = CertFile, api_key = ApiKey} = State) ->
    ?DEBUG("+++++ Sending push notification to ~p", [?PUSH_URL]),
    PushMessage =
    {struct,
     [{to, Token}, {time_to_live, ?EXPIRY_TIME}, {data, Payload}]},
    ?DEBUG("+++++++ PushMessage (before encoding): ~p", [PushMessage]),
    Body = iolist_to_binary(mochijson2:encode(PushMessage)),
    ?DEBUG("+++++++ encoded json: ~s", [Body]),
    SslOpts =
    [{certfile, CertFile}, {versions, ['tlsv1.2']}, {ciphers, ?CIPHERSUITES},
     {server_name_indication, disable}, {reuse_sessions, true}],
    HttpOpts =
    [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT},
     {ssl, SslOpts}],
    Opts =
    [],
    Authorization =
    "key=" ++ binary_to_list(ApiKey),
    Request =
    {?PUSH_URL, [{"Authorization", Authorization}], "application/json", Body},
    Reply =
    try httpc:request(post, Request, HttpOpts, Opts) of
        {ok, {{_,200,_},_,RespBody}} ->
                    {ok, mochijson2:decode(RespBody)};
        {error, Reason } ->
                    {error, Reason};
        {ok, {{StatusLine,_,_},_,RespBody}} ->
                    {error, {StatusLine, RespBody}};
        BigError -> {error, BigError}
    catch
        Throw -> {error, caught, Throw}
    end,
    ?DEBUG("++++++++ Server replied: ~p", [Reply]),

    %DisableCb(),
    % FIXME: set too_many_pending according to server response
    {noreply, State};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, State) -> {noreply, State}.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------
