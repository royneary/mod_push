%%%----------------------------------------------------------------------
%%% File    : mod_push_wns.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : Send push notifications to the Windows Notification Service
%%% Created : 16 Jun 2015 by Christian Ulrich <christian@rechenwerk.net>
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

-module(mod_push_wns).

-author('christian@rechenwerk.net').

-behaviour(gen_server).

-export([init/1,
         handle_info/2,
         handle_call/3,
         handle_cast/2,
         terminate/2,
         code_change/3]).

-include("logger.hrl").

-define(AUTHENTICATION_URL, "https://login.live.com/accesstoken.srf").
-define(AUTHENTICATION_SCOPE, <<"notify.windows.com">>).
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
         package_sid :: binary(),
         client_secret :: binary(),
         access_token :: string()}).

%-------------------------------------------------------------------------

init([ClientSecret, PackageSid, CertFile]) ->
    ?DEBUG("+++++++++ mod_push_wns:init", []),
    inets:start(),
    ssl:start(),
    AccessToken =
    case authenticate(PackageSid, ClientSecret, CertFile) of
        {ok, Token} -> Token;
        _ -> undefined
    end,
    {ok,
     #state{certfile = CertFile, package_sid = PackageSid,
            client_secret = ClientSecret, access_token = AccessToken}}.

%-------------------------------------------------------------------------

handle_info(_Info, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_call(_Req, _From, State) -> {noreply, State}.

%-------------------------------------------------------------------------

handle_cast({dispatch, _UserBare, Payload, ChannelUrl, _AppId, DisableArgs},
            #state{certfile = CertFile, access_token = AccessToken} = State) ->
    case is_list(AccessToken) of
        false ->
            ?DEBUG("+++++ cannot dispatch notification, not authenticated", []);

        true ->
            ?DEBUG("+++++ Sending push notification to ~p", [ChannelUrl]),
            SslOpts =
            [{certfile, CertFile}, {versions, ['tlsv1.2']},
             {ciphers, ?CIPHERSUITES}, {server_name_indication, disable},
             {reuse_sessions, true}],
            HttpOpts =
            [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT},
             {ssl, SslOpts}],
            Opts =
            [],
            %% FIXME: The WNS raw notificatoin guidelines say:
            %% Validate that the channel URL is from WNS. Never attempt to push
            %% a notification to a service that isn't WNS. Ensure that your
            %% channel URLs use the "windows.com" domain.
            DecodedUrl = http_uri:decode(binary_to_list(ChannelUrl)),
            Header =
            [{"Authorization", "Bearer " ++ AccessToken},
             {"X-WNS-TYPE", "wns/raw"}],
            Body =
            base64:encode(list_to_binary(mochijson2:encode({struct, Payload}))),
            Request = {DecodedUrl, Header, "application/octet-stream", Body},
            Reply =
            try httpc:request(post, Request, HttpOpts, Opts) of
                {ok, {{_,200,_},_,_ReplyBody}} ->
                    ok;
                {error, Reason } ->
                    {error, Reason};
                {ok, Other} ->
                    {error, Other}
            catch
                Throw -> {error, caught, Throw}
            end,
            ?DEBUG("++++++++ Server replied: ~p", [Reply])
    end,
    {noreply, State};

handle_cast(_Req, State) -> {reply, {error, badarg}, State}.

%-------------------------------------------------------------------------

terminate(_Reason, State) -> {noreply, State}.

%-------------------------------------------------------------------------

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%-------------------------------------------------------------------------

authenticate(PackageSid, ClientSecret, CertFile) ->
    SslOpts =
    [{certfile, CertFile}, {versions, ['tlsv1.2']}, {ciphers, ?CIPHERSUITES},
     {server_name_indication, disable}, {reuse_sessions, true}],
    HttpOpts =
    [{timeout, ?HTTP_TIMEOUT}, {connect_timeout, ?HTTP_CONNECT_TIMEOUT},
     {ssl, SslOpts}],
    Opts = [],
    Body =
    url_encode([{<<"grant_type">>, <<"client_credentials">>},
                {<<"client_id">>, PackageSid},
                {<<"client_secret">>, ClientSecret},
                {<<"scope">>, ?AUTHENTICATION_SCOPE}]),
    Request = {?AUTHENTICATION_URL, [], "application/x-www-form-urlencoded",
               Body},
    Reply =
    try httpc:request(post, Request, HttpOpts, Opts) of
        {ok, {{_,200,_}, ReplyHead, ReplyBody}} ->
            {struct, ReplyPayload} = mochijson2:decode(ReplyBody),
            case proplists:get_value(<<"access_token">>, ReplyPayload) of
                AccessToken when is_binary(AccessToken) ->
                    {ok, binary_to_list(AccessToken)};
                _ -> {error, "no access token"}
            end;
    
        {error, Reason} -> {error, Reason};
        Other ->
            ?DEBUG("+++++ WNS channel replied: ~p", [Other]),
            {error, "unexpected reply"}
    catch
        _ -> {error, "could not connect to authentication server"}
    end,
    ?DEBUG("++++++ Server replies: ~p", [Reply]),
    Reply.

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
