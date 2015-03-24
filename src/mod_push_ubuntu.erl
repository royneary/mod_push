%%%----------------------------------------------------------------------
%%% File    : mod_push_ubuntu.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : Send push notifications to the Ubuntu Push service
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

-module(mod_push_ubuntu).

-author('christian@rechenwerk.net').

-behaviour(gen_server).

-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

%-include("mod_push.hrl").
-include("logger.hrl").

-define(PUSH_URL, "https://push.ubuntu.com/notify").
-define(EXPIRY_TIME, 60*60*24).
-define(HTTP_TIMEOUT, 10000).
-define(HTTP_CONNECT_TIMEOUT, 10000).
-define(CIPHERSUITES,
        [{K,C,H} || {K,C,H} <- ssl:cipher_suites(erlang),
                    K =/= ecdh_ecdsa, K =/= ecdh_rsa, K =/= rsa,
                    C =/= rc4_128, C =/= des_cbc, C =/= '3des_ede_cbc',
                    H =/= sha, H =/= md5]).

% TODO: add message_queue
-record(state,
        {certfile :: binary(),
         too_many_pending = false :: boolean()}).

%-------------------------------------------------------------------------

init([_Host, _AuthKey, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_up:init", []),
    inets:start(),
    ssl:start(),
    {ok, #state{certfile = CertFile}}.

%-------------------------------------------------------------------------

handle_info(_Info, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) ->
    {noreply, State}.

%-------------------------------------------------------------------------

handle_cast({dispatch, Payload, Token, AppId, _Silent, DisableArgs},
            #state{certfile = CertFile,
                   too_many_pending = TooManyPending} = State) ->
    % TODO: right now the clear_pending field is set if server replied with a
    % too-many-pending error or if the include_senders option is set false. 
    % There's an optional 'tag' field which we can use to tell the proprietary
    % server to clear pending notifications triggered by the same sender in order to
    % save bandwidth from proprietary server to client. So store a random tag per
    % sender and set replace_tag: "sender_tag" in each push notification
    ?DEBUG("Sending push notification to proprietary push server!", []),
    ClearPending =
    TooManyPending, %or (FromL =:= undefined),
    PushMessage =
    {struct,
     [{appid, AppId}, {expire_on, expiry_time()}, {token, Token},
      {clear_pending, ClearPending},
      {data, Payload}]},
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
    Request = {?PUSH_URL, [], "application/json", Body},
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
    {noreply, State#state{too_many_pending = false}};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, State) -> {noreply, State}.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------

%make_data(Sender, MsgCount, Sid) ->
%    SidPart = case Sid of
%        <<"">> -> [];
%        undefined -> [];
%        _ -> [{session_id, Sid}]
%    end,
%    SenderPart = case Sender of
%        undefined -> [];
%        _ -> [{message_sender, jlib:jid_to_string(Sender)}]
%    end,
%    MsgCountPart = case MsgCount of
%        undefined -> [];
%        _ -> [{message_count, MsgCount}]
%    end,
%    {struct, SidPart ++ SenderPart ++ MsgCountPart}.

%-------------------------------------------------------------------------

expiry_time() ->
    Now = os:timestamp(),
    {_, Seconds, _} = Now,
    Time = setelement(2, Now, Seconds + ?EXPIRY_TIME),
    {{Y, M, D}, {Hour, Min, Sec}} = calendar:now_to_universal_time(Time),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
                                   [Y, M, D, Hour, Min, Sec])).

%-------------------------------------------------------------------------

