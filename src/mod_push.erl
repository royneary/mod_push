%%%----------------------------------------------------------------------
%%% File    : mod_push.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : implements XEP-0357 Push and an IM-focussed app server
%%%           
%%% Created : 22 Dec 2014 by Christian Ulrich <christian@rechenwerk.net>
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

-module(mod_push).

-author('christian@rechenwerk.net').

-behaviour(gen_mod).

-export([start/2, stop/1,
         mod_opt_type/1,
         get_backend_opts/1,
         process_iq/3,
         on_store_stanza/3,
         incoming_notification/4,
         on_affiliation_removal/4,
         on_unset_presence/4,
         on_resume_session/1,
         on_wait_for_resume/3,
         on_disco_sm_features/5,
         on_disco_pubsub_info/5,
         on_disco_reg_identity/5,
         on_disco_sm_identity/5,
         on_remove_user/2,
         process_adhoc_command/4,
         resend_packets/1,
         unregister_client/2,
         check_secret/2]).

-include("logger.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

-define(MODULE_APNS, mod_push_apns).
-define(MODULE_GCM, mod_push_gcm).
-define(MODULE_MOZILLA, mod_push_mozilla).
-define(MODULE_UBUNTU, mod_push_ubuntu).
-define(MODULE_WNS, mod_push_wns).

-define(NS_PUSH, <<"urn:xmpp:push:0">>).
-define(NS_PUSH_SUMMARY, <<"urn:xmpp:push:summary">>).
-define(NS_PUSH_OPTIONS, <<"urn:xmpp:push:options">>).
-define(NS_PUBLISH_OPTIONS,
        <<"http://jabber.org/protocol/pubsub#publish-options">>).

-define(INCLUDE_SENDERS_DEFAULT, false).
-define(INCLUDE_MSG_COUNT_DEFAULT, true).
-define(INCLUDE_SUBSCR_COUNT_DEFAULT, true).
-define(INCLUDE_MSG_BODIES_DEFAULT, false).
-define(SILENT_PUSH_DEFAULT, true).

-define(MAX_INT, 4294967295).
-define(ADJUSTED_RESUME_TIMEOUT, 100*24*60*60).

%-------------------------------------------------------------------------
% xdata-form macros
%-------------------------------------------------------------------------

-define(VVALUE(Val),
(
    #xmlel{
        name     = <<"value">>,
        children = [{xmlcdata, Val}]
    }
)).

-define(VFIELD(Var, Val),
(
    #xmlel{
        name = <<"field">>,
        attrs = [{<<"var">>, Var}],
        children = vvaluel(Val)
    }
)).

-define(TVFIELD(Type, Var, Vals),
(
    #xmlel{
        name     = <<"field">>,
        attrs    = [{<<"type">>, Type}, {<<"var">>, Var}],
        children =
        lists:foldl(fun(Val, FieldAcc) -> vvaluel(Val) ++ FieldAcc end,
                    [], Vals)
    }
)).

-define(HFIELD(Val), ?TVFIELD(<<"hidden">>, <<"FORM_TYPE">>, [Val])).

-define(ITEM(Fields),
(
    #xmlel{name = <<"item">>,
           children = Fields}
)).

%-------------------------------------------------------------------------

-record(auth_data,
        {auth_key = <<"">> :: binary(),
         package_sid = <<"">> :: binary(),
         certfile = <<"">> :: binary()}).

-record(subscription, {resource :: binary(),
                       pending = false :: boolean(),
                       node :: binary(),
                       reg_type :: reg_type()}).

%% mnesia table
-record(push_user, {bare_jid :: bare_jid(),
                    subscriptions :: [subscription()],
                    config :: user_config(),
                    payload = [] :: payload()}).

%% mnesia table
-record(push_registration, {node :: binary(),
                            bare_jid :: bare_jid(),
                            device_id :: binary(),
                            device_name :: binary(),
                            token :: binary(),
                            secret :: binary(),
                            app_id :: binary(),
                            backend_id :: integer(),
                            timestamp = now() :: erlang:timestamp()}).

%% mnesia table
-record(push_backend,
        {id :: integer(),
         register_host :: binary(),
         pubsub_host :: binary(),
         type :: backend_type(),
         app_name :: binary(),
         cluster_nodes = [] :: [atom()],
         worker :: binary()}).

%% mnesia table
-record(push_stored_packet, {receiver :: ljid(),
                             sender :: jid(),
                             timestamp = now() :: erlang:timestamp(),
                             packet :: xmlelement()}).

-type auth_data() :: #auth_data{}.
-type backend_type() :: apns | gcm | mozilla | ubuntu | wns.
-type bare_jid() :: {binary(), binary()}.
-type payload_key() ::
    'last-message-sender' | 'last-subscription-sender' | 'message-count' |
    'pending-subscription-count' | 'last-message-body'.
-type payload_value() :: binary() | integer().
-type payload() :: [{payload_key(), payload_value()}].
-type push_backend() :: #push_backend{}.
-type push_registration() :: #push_registration{}.
-type reg_type() :: {local_reg, binary(), binary()} | % pubsub host, secret
                    {remote_reg, jid(), binary()}.  % pubsub host, secret
-type subscription() :: #subscription{}.
-type user_config_option() ::
    'include-senders' | 'include-message-count' | 'include-subscription-count' |
    'include-message-bodies'.
-type user_config() :: [user_config_option()].

%-------------------------------------------------------------------------

-spec(register_client/7 ::
(
    User :: jid(),
    RegisterHost :: binary(),
    Type :: backend_type(),
    Token :: binary(),
    DeviceId :: binary(),
    DeviceName :: binary(),
    AppId :: binary())
    -> {registered,
        PubsubHost :: binary(),
        Node :: binary(),
        Secret :: binary()}
).

register_client(#jid{lresource = <<"">>}, _, _, _, <<"">>, _, _) ->
    error;

register_client(#jid{lresource = <<"">>}, _, _, _, undefined, _, _) ->
    error;

register_client(#jid{luser = LUser,
                     lserver = LServer,
                     lresource = LResource},
                RegisterHost, Type, Token, DeviceId, DeviceName, AppId) ->
    F = fun() ->
        MatchHeadBackend =
        #push_backend{register_host = RegisterHost, type = Type, _='_'},
        MatchingBackends =
        mnesia:select(push_backend, [{MatchHeadBackend, [], ['$_']}]),
        case MatchingBackends of
            [#push_backend{id = BackendId, pubsub_host = PubsubHost}|_] ->
                ?DEBUG("+++++ register_client: found backend", []),
                ChosenDeviceId = case DeviceId of
                    undefined -> LResource;
                    <<"">> -> LResource;
                    _ -> DeviceId
                end,
                Secret = randoms:get_string(),
                MatchHeadReg =
                #push_registration{bare_jid = {LUser, LServer},
                                   device_id = ChosenDeviceId, _='_'},
                ExistingReg =
                mnesia:select(push_registration, [{MatchHeadReg, [], ['$_']}]),
                Registration =
                case ExistingReg of
                    [] ->
                        NewNode = randoms:get_string(),
                        #push_registration{node = NewNode,
                                           bare_jid = {LUser, LServer},
                                           device_id = ChosenDeviceId,
                                           device_name = DeviceName,
                                           token = Token,
                                           secret = Secret,
                                           app_id = AppId,
                                           backend_id = BackendId};

                    [OldReg] ->
                        OldReg#push_registration{device_name = DeviceName,
                                                 token = Token,
                                                 secret = Secret,
                                                 app_id = AppId,
                                                 backend_id = BackendId,
                                                 timestamp = now()}
                end,
                mnesia:write(Registration),
                {PubsubHost, Registration#push_registration.node,
                 Registration#push_registration.secret};
            
            _ ->
                ?DEBUG("+++++ register_client: found no backend", []),
                error
        end
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> {error, ?ERR_ITEM_NOT_FOUND};
        {atomic, Result} -> {registered, Result}
    end. 

%-------------------------------------------------------------------------

%% Callback for workers

-spec(unregister_client/2 ::
(
    Node :: binary(),
    Timestamp :: erlang:timestamp())
    -> error | {error, xmlelement()} | {unregistered, ok} |
       {unregistered, [binary()]}
).

unregister_client(Node, Timestamp) ->
    unregister_client(undefined, undefined, Timestamp, [Node]). 

%-------------------------------------------------------------------------

%% Either device ID or a list of node IDs must be given. If none of these are in
%% the payload, the resource of the from jid will be interpreted as device ID.
%% If both device ID and node list are given, the device_id will be ignored and
%% only registrations matching a node ID in the given list will be removed.

-spec(unregister_client/3 ::
(
    Jid :: jid(),
    DeviceId :: binary(),
    NodeIds :: [binary()])
    -> error | {error, xmlelement()} | {unregistered, ok} |
       {unregistered, [binary()]}
).

unregister_client(Jid, DeviceId, NodeIds) ->
    unregister_client(Jid, DeviceId, '_', NodeIds).

%-------------------------------------------------------------------------

-spec(unregister_client/4 ::
(
    UserJid :: jid(),
    DeviceId :: binary(),
    Timestamp :: erlang:timestamp(),
    Nodes :: [binary()])
    -> error | {error, xmlelement()} | {unregistered, ok} |
       {unregistered, [binary()]}
).

unregister_client(#jid{lresource = <<"">>}, undefined, _, []) -> error;
unregister_client(#jid{lresource = <<"">>}, <<"">>, _, []) -> error;
unregister_client(undefined, undefined, _, []) -> error;
unregister_client(undefined, <<"">>, _, []) -> error;

unregister_client(UserJid, DeviceId, Timestamp, Nodes) ->
    DisableIfLocal =
    fun(#push_registration{node = Node,
                           bare_jid = {User, Server},
                           backend_id = BackendId}) ->
        MatchHeadBackend =
        #push_backend{id = BackendId, pubsub_host = '$1', _='_'},
        Selected =
        mnesia:select(push_backend, [{MatchHeadBackend, [], ['$1']}]),
        case Selected of
            [] -> ?DEBUG("++++ Backend does not exist!", []);
            [PubsubHost] ->
                PubsubJid = ljid_to_jid({<<"">>, PubsubHost, <<"">>}),
                UserBareJid = ljid_to_jid({User, Server, <<"">>}),
                case is_local_domain(Server) of
                    false ->
                        PubsubNotification =
                        #xmlel{
                            name = <<"pubsub">>,
                            attrs = [{<<"xmlns">>, ?NS_PUBSUB}],
                            children =
                            [#xmlel{
                                name = <<"affiliations">>,
                                attrs = [{<<"node">>, Node}],
                                children =
                                [#xmlel{
                                    name = <<"affiliation">>,
                                    attrs = [{<<"jid">>,
                                              jlib:jid_to_string(UserBareJid)},
                                             {<<"affiliation">>,
                                              <<"none">>}]}]}]},
                        PubsubMessage =
                        #xmlel{
                           name = <<"message">>,
                           attrs = [],
                           children = [PubsubNotification]},
                        ejabberd_router:route(
                            PubsubJid,
                            UserBareJid,
                            PubsubMessage);

                    true ->
                        disable(UserBareJid, PubsubJid, Node, true)
                end
        end
    end,
    F = fun() ->
        case Nodes of
            [] ->
                #jid{luser = LUser, lserver= LServer, lresource = LResource} =
                UserJid,
                ChosenDeviceId = case DeviceId of
                    undefined -> LResource;
                    <<"">> -> LResource;
                    _ -> DeviceId
                end,
                MatchHead =
                #push_registration{bare_jid = {LUser, LServer},
                                   device_id = ChosenDeviceId,
                                   timestamp = Timestamp,
                                   _='_'},
                MatchingReg =
                mnesia:select(push_registration, [{MatchHead, [], ['$_']}]),
                case MatchingReg of
                    [] -> error;

                    [Reg] ->
                        ?DEBUG("+++++ deleting registration of user ~p whith node "
                               "~p",
                               [Reg#push_registration.bare_jid,
                                Reg#push_registration.node]),
                        mnesia:delete_object(Reg),
                        DisableIfLocal(Reg),
                        ok
                end;

            GivenNodes ->
                UnregisteredNodes =
                lists:foldl(
                    fun(Node, Acc) ->
                        RegResult = mnesia:read({push_registration, Node}),
                        case RegResult of
                            [] -> Acc;
                            [Reg] ->
                                UserOk =
                                case UserJid of
                                    #jid{luser = LUser, lserver = LServer} ->
                                        BareJid = 
                                        Reg#push_registration.bare_jid,
                                        BareJid =:= {LUser, LServer};
                                    undefined -> true
                                end,
                                case UserOk of
                                    true ->
                                        mnesia:delete_object(Reg),
                                        DisableIfLocal(Reg),
                                        [Node|Acc];
                                    false -> [error|Acc]
                                end
                        end
                    end,
                    [],
                    GivenNodes),
                case [El || El <- UnregisteredNodes, El =:= error] of
                    [] -> UnregisteredNodes;
                    _ -> error
                end
        end
    end,
    case mnesia:transaction(F) of
        {aborted, Reason} ->
            ?DEBUG("+++++ unregister_client error: ~p", [Reason]),
            {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> error;
        {atomic, Result} -> {unregistered, Result}
    end.
                                         
%-------------------------------------------------------------------------

-spec(enable/4 ::
(
    UserJid :: jid(),
    PubsubJid :: jid(),
    Node :: binary(),
    XData :: [false | xmlelement()])
    -> {error, xmlelement()} | {enabled, ok} | {enabled, [xmlelement()]}
).

enable(_UserJid, _PubsubJid, undefined, _XDataForms) ->
    {error, ?ERR_NOT_ACCEPTABLE};

enable(_UserJid, _PubsubJid, <<"">>, _XDataForms) ->
    {error, ?ERR_NOT_ACCEPTABLE};

enable(#jid{luser = LUser, lserver = LServer, lresource = LResource},
       #jid{lserver = PubsubHost} = PubsubJid, Node, XDataForms) ->
    ParsedSecret =
    parse_form(XDataForms, ?NS_PUBLISH_OPTIONS, [], [{single, <<"secret">>}]),
    ?DEBUG("+++++ ParsedSecret = ~p", [ParsedSecret]),
    Secret = case ParsedSecret of
        not_found -> undefined; 
        error -> error;
        {result, [S]} -> S
    end,
    case Secret of
        error -> {error, ?ERR_BAD_REQUEST}; 
        _ ->
            F = fun() ->
                MatchHeadBackend =
                #push_backend{id = '$1', pubsub_host = PubsubHost, _='_'},
                RegType =
                case mnesia:select(push_backend, [{MatchHeadBackend, [], ['$1']}]) of
                    [] -> {remote_reg, PubsubJid, Secret};
                    _ -> {local_reg, PubsubHost, Secret}
                end,
                Subscr =
                #subscription{resource = LResource,
                              node = Node,
                              reg_type = RegType},
                case mnesia:read({push_user, {LUser, LServer}}) of
                    [] ->
                        ?DEBUG("+++++ enable: no user found!", []),
                        GConfig = get_global_config(LServer),
                        case make_config(XDataForms, GConfig, enable_disable) of
                            error -> error;
                            {Config, ChangedOpts} ->
                                %% NewUser will have empty payload
                                NewUser =
                                #push_user{bare_jid = {LUser, LServer},
                                           subscriptions = [Subscr],
                                           config = Config},
                                mnesia:write(NewUser),
                                make_config_form(ChangedOpts)
                        end;
                    
                    [#push_user{subscriptions = Subscriptions,
                                config = OldConfig}] ->
                        ?DEBUG("+++++ enable: found user, config = ~p", [OldConfig]),
                        case make_config(XDataForms, OldConfig, disable_only) of
                            error -> error;
                            {Config, ChangedOpts} -> 
                                FilterNode =
                                fun
                                    (S) when S#subscription.node =:= Node;
                                             S#subscription.resource =:= LResource ->
                                        false;
                                    (_) -> true
                                end,
                                NewSubscriptions =
                                [Subscr|lists:filter(FilterNode, Subscriptions)],
                                %% NewUser will have empty payload
                                NewUser =
                                #push_user{bare_jid = {LUser, LServer},
                                           subscriptions = NewSubscriptions,
                                           config = Config},
                                mnesia:write(NewUser),
                                make_config_form(ChangedOpts)
                        end
                end
            end,
            case mnesia:transaction(F) of
                {aborted, Reason} ->
                    ?DEBUG("+++++ enable transaction aborted: ~p", [Reason]),
                    {error, ?ERR_INTERNAL_SERVER_ERROR};
                {atomic, error} -> {error, ?ERR_NOT_ACCEPTABLE};
                {atomic, []} -> {enabled, ok};
                {atomic, ResponseForm} -> {enabled, ResponseForm}
            end
    end.
                
%-------------------------------------------------------------------------

-spec(disable/3 ::
(
    From :: jid(),
    PubsubJid :: jid(),
    Node :: binary())
    -> {error, xmlelement()} | {disabled, ok} 
).

disable(From, PubsubJid, Node) -> disable(From, PubsubJid, Node, false).

%-------------------------------------------------------------------------

-spec(disable/4 ::
(
    From :: jid(),
    PubsubJid :: jid(),
    Node :: binary(),
    StopSessions :: boolean())
    -> {error, xmlelement()} | {disabled, ok} 
).

disable(_From, _PubsubJid, <<"">>, _StopSessions) ->
    {error, ?ERR_NOT_ACCEPTABLE};

disable(#jid{luser = LUser, lserver = LServer},
        #jid{lserver = PubsubHost} = PubsubJid, Node, StopSessions) ->
    SubscrPred =
    fun
        (#subscription{node = N, reg_type = RegT}) ->
            NodeMatching =
            (Node =:= undefined) or (Node =:= N),
            RegTypeMatching =
            case RegT of
                {local_reg, P, _} -> P =:= PubsubHost;
                {remote_reg, J, _} ->
                    (J#jid.luser =:= PubsubJid#jid.luser) and
                    (J#jid.lserver =:= PubsubJid#jid.lserver) and
                    (J#jid.lresource =:= PubsubJid#jid.lresource)
            end,
            NodeMatching and RegTypeMatching
    end,
    case delete_subscriptions({LUser, LServer}, SubscrPred, StopSessions) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> {error, ?ERR_ITEM_NOT_FOUND};
        {atomic, ok} -> {disabled, ok}
    end.
       
%-------------------------------------------------------------------------

-spec(delete_subscriptions/3 ::
(
    BareJid :: bare_jid(),
    SubscriptionPred :: fun((subscription()) -> boolean()),
    StopSessions :: boolean())
    -> {aborted, any()} | {atomic, error} | {atomic, ok}
).

delete_subscriptions({LUser, LServer}, SubscriptionPred, StopSessions) ->
    MaybeStopSession = fun(Subscription) ->
        case Subscription#subscription.pending of
            false -> ok;
            true ->
                Pid =
                ejabberd_sm:get_session_pid(LUser, LServer,
                                            Subscription#subscription.resource),
                case Pid of
                    P when is_pid(P) ->
                        %% FIXME: replace by P ! stop
                        P ! kick; 
                    _ ->
                        ?DEBUG("++++ Didn't find PID for ~p@~p/~p",
                               [LUser, LServer, Subscription#subscription.resource])
                end
        end
    end,
    F = fun() ->
        case mnesia:read({push_user, {LUser, LServer}}) of
            [] -> error;
            [#push_user{subscriptions = Subscriptions} = User] ->
                {MatchingSubscrs, NotMatchingSubscrs} =
                lists:partition(SubscriptionPred, Subscriptions),
                case MatchingSubscrs of
                    [] -> error;
                    _ ->
                        ?DEBUG("+++++ Deleting subscriptions for user ~p@~p", [LUser, LServer]),
                        case StopSessions of
                            false -> ok;
                            true ->
                                lists:foreach(MaybeStopSession, MatchingSubscrs)
                        end,
                        case NotMatchingSubscrs of
                            [] ->
                                mnesia:delete({push_user, {LUser, LServer}});
                            _ ->
                                UpdatedUser =
                                User#push_user{subscriptions = NotMatchingSubscrs},
                                mnesia:write(UpdatedUser)
                        end
                end
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(list_registrations/1 ::
(jid()) -> {error, xmlelement()} | {registrations, [push_registration()]}).

list_registrations(#jid{luser = LUser, lserver = LServer}) ->
    F = fun() ->
        MatchHead = #push_registration{bare_jid = {LUser, LServer}, _='_'},
        mnesia:select(push_registration, [{MatchHead, [], ['$_']}])
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, RegList} -> {registrations, RegList}
    end.

%-------------------------------------------------------------------------

-spec(on_store_stanza/3 ::
(
    Acc :: any(),
    To :: jid(),
    Stanza :: xmlelement())
    -> any()
).

%% called on hook mgmt_queue_add_hook
on_store_stanza(RerouteFlag, To, Stanza) ->
    ?DEBUG("++++++++++++ Stored Stanza for ~p: ~p",
           [To, Stanza]),
    F = fun() -> dispatch([{now(), Stanza}], To, false) end,
    case mnesia:transaction(F) of
        {atomic, not_subscribed} -> RerouteFlag;
        
        {atomic, ok} ->
            case RerouteFlag of
                true -> false_on_system_shutdown;
                _ -> RerouteFlag
            end;

        {aborted, Error} ->
            ?DEBUG("+++++ error in on_store_stanza: ~p", [Error]),
            RerouteFlag
    end.
                                      
%-------------------------------------------------------------------------

-spec(dispatch/3 ::
(
    Stanzas :: [{erlang:timestamp(), xmlelement(), boolean()}],
    UserJid :: jid(),
    SetPending :: boolean())
    -> ok | not_subscribed
).

dispatch(Stanzas, UserJid, SetPending) ->
    #jid{luser = LUser, lserver = LServer, lresource = LResource} = UserJid,
    case mnesia:read({push_user, {LUser, LServer}}) of
        [] -> not_subscribed;
        [PushUser] ->
            ?DEBUG("+++++ dispatch: found push_user", []),
            #push_user{subscriptions = Subscrs, config = Config,
                       payload = OldPayload} = PushUser,
            NewSubscrs = case SetPending of
                true -> set_pending(LResource, true, Subscrs);
                false -> Subscrs
            end,
            ?DEBUG("+++++ NewSubscrs = ~p", [NewSubscrs]),
            MatchingSubscr =
            [M || #subscription{pending = P, resource = R} = M <- NewSubscrs,
                  P =:= true, R =:= LResource],
            case MatchingSubscr of
                [] -> not_subscribed;
                [#subscription{reg_type = RegType, node = NodeId}] ->
                    ?DEBUG("+++++ dispatch: found subscription", []),
                    WriteUser =
                    fun(Payload) ->
                        NewPayload = case Payload of
                            none -> OldPayload;
                            _ -> Payload
                        end,
                        NewUser =
                        PushUser#push_user{subscriptions = NewSubscrs,
                                           payload = NewPayload},
                        mnesia:write(NewUser)
                    end,
                    case make_payload(Stanzas, OldPayload, Config) of
                        none ->
                            ?DEBUG("+++++ dispatch: no payload", []),
                            case SetPending of
                                true -> WriteUser(none);
                                false -> ok
                            end;

                        {payload, Payload, StanzasToStore} ->
                            ?DEBUG("+++++ dispatch: payload ~p", [Payload]),
                            Receiver = jlib:jid_tolower(UserJid),
                            lists:foreach(
                                fun({Timestamp, Stanza}) ->
                                    StoredPacket =
                                    #push_stored_packet{receiver = Receiver,
                                                        timestamp = Timestamp,
                                                        packet = Stanza},
                                    mnesia:write(StoredPacket)
                                end,
                                StanzasToStore),
                            WriteUser(Payload),
                            do_dispatch(RegType, {LUser, LServer}, NodeId,
                                        Payload)
                    end
            end
    end.
                                            
%-------------------------------------------------------------------------

-spec(do_dispatch/4 ::
(
    RegType :: reg_type(),
    UserBare :: bare_jid(),
    NodeId :: binary(),
    Payload :: payload())
    -> dispatched | ok
).

do_dispatch({local_reg, _, Secret}, UserBare, NodeId, Payload) ->
    SelectedReg = mnesia:read({push_registration, NodeId}),
    case SelectedReg of
        [] ->
            ?INFO_MSG("push event for local user ~p, but user is not registered"
                      " at local app server", [UserBare]);
       
        [#push_registration{node = Node,
                            bare_jid = StoredUserBare,
                            token = Token,
                            secret = StoredSecret,
                            app_id = AppId,
                            backend_id = BackendId,
                            timestamp = Timestamp}] ->
            case {UserBare, Secret} of
                {StoredUserBare, StoredSecret} ->
                    
                    ?DEBUG("+++++ do_dispatch: found registration, dispatch locally",
                           []),
                    do_dispatch_local(Payload, Token, AppId, BackendId, Node,
                                      Timestamp, true);

                {StoredUserBare, _} -> 
                    ?INFO_MSG("push event for local user ~p, but secret does "
                              "not match", [UserBare]);

                _ ->
                    ?INFO_MSG("push event for local user ~p, but the "
                              "user-provided node belongs to another user",
                              [UserBare]) 
            end
    end;

do_dispatch({remote_reg, PubsubHost, Secret}, UserBare, NodeId, Payload) ->
    ?DEBUG("++++ do_dispatch: dispatching remotely", []),
    do_dispatch_remote(UserBare, PubsubHost, NodeId, Payload, Secret),
    ok.

%-------------------------------------------------------------------------

-spec(do_dispatch_local/7 ::
(
    Payload :: payload(),
    Token :: binary(),
    AppId :: binary(),
    BackendId :: integer(),
    Node :: binary(),
    Timestamp :: erlang:timestamp(),
    AllowRelay :: boolean())
    -> ok
).

do_dispatch_local(Payload, Token, AppId, BackendId, Node, Timestamp,
                  AllowRelay) ->
    DisableArgs = {Node, Timestamp},
    [#push_backend{worker = Worker, cluster_nodes = ClusterNodes}] =
    mnesia:read({push_backend, BackendId}),
    case lists:member(node(), ClusterNodes) of
        true ->
            ?DEBUG("+++++ dispatch_local: calling worker", []),
            gen_server:cast(Worker,
                            {dispatch, Payload, Token, AppId, DisableArgs});

        false ->
            case AllowRelay of
                false ->
                    ?DEBUG("+++++ Worker ~p is not running, cancel dispatching "
                           "push notification", [Worker]);
                true ->
                    Index = random:uniform(length(ClusterNodes)),
                    ChosenNode = lists:nth(Index, ClusterNodes),
                    ?DEBUG("+++++ Relaying push notification to node ~p",
                           [ChosenNode]),
                    gen_server:cast(
                        {Worker, ChosenNode},
                        {dispatch,
                         Payload, Token, AppId, DisableArgs})
            end
    end.
           
%-------------------------------------------------------------------------

-spec(do_dispatch_remote/5 ::
(
    UserBare :: bare_jid(),
    PubsubJid :: jid(),
    Node :: binary(),
    Payload :: payload(),
    Secret :: binary())
    -> any()
).

do_dispatch_remote({User, Server}, PubsubJid, Node, Payload, Secret) ->
    MakeKey = fun(Atom) -> atom_to_binary(Atom, utf8) end,
    Fields =
    lists:foldl(
        fun
        ({Key, Value}, Acc) when is_binary(Value) ->
            [?VFIELD(MakeKey(Key), Value)|Acc];

        ({Key, Value}, Acc) when is_integer(Value) ->
            [?VFIELD(MakeKey(Key), integer_to_binary(Value))|Acc]
        end,
        [?HFIELD(?NS_PUSH_SUMMARY)],
        Payload),
    Notification =
    #xmlel{name = <<"notification">>, attrs = [{<<"xmlns">>, ?NS_PUSH}],
           children =
           [#xmlel{name = <<"x">>,
                   attrs = [{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"submit">>}],
                   children = Fields}]},
    PubOpts =
    case is_binary(Secret) of
        true ->
            [#xmlel{name = <<"publish-options">>,
                    children =
                    [#xmlel{name = <<"x">>,
                            attrs = [{<<"xmlns">>, ?NS_XDATA},
                                     {<<"type">>, <<"submit">>}],
                            children = [?HFIELD(?NS_PUBLISH_OPTIONS),
                                        ?VFIELD(<<"secret">>, Secret)]}]}];
        false -> []
    end,
    Iq =
    #xmlel{name = <<"iq">>, attrs = [{<<"type">>, <<"set">>}],
        children =
        [#xmlel{name = <<"pubsub">>, attrs = [{<<"xmlns">>, ?NS_PUBSUB}],
                children =
                [#xmlel{name = <<"publish">>, attrs = [{<<"node">>, Node}],
                        children =
                        [#xmlel{name = <<"item">>,
                                children = [Notification]}]}] ++ PubOpts}]},
    ejabberd_router:route(ljid_to_jid({User, Server, <<"">>}), PubsubJid, Iq).

%-------------------------------------------------------------------------

-spec(on_unset_presence/4 ::
(
    User :: binary(),
    Server :: binary(),
    Resource :: binary(),
    Status :: binary())
    -> any()
).

on_unset_presence(User, Server, Resource, _Status) ->
    SubscrPred =
    fun(#subscription{resource = LResource}) -> LResource =:= Resource end,
    delete_subscriptions({User, Server}, SubscrPred, false),
    F = fun() ->
        mnesia:delete({push_stored_packet, {User, Server, Resource}})
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(resend_packets/1 :: (Jid :: jid()) -> ok).

resend_packets(Jid) ->
    F = fun() ->
        LJid = jlib:jid_tolower(Jid),
        Packets = mnesia:read({push_stored_packet, LJid}),
        ?DEBUG("+++++++ resending packets to user ~p", [jlib:jid_to_string(LJid)]),
        lists:foreach(
            fun(#push_stored_packet{timestamp = T, packet = P}) ->
	            FromS = proplists:get_value(<<"from">>, P#xmlel.attrs),
                From = jlib:string_to_jid(FromS),
                StampedPacket = jlib:add_delay_info(P, Jid#jid.lserver, T),
                ejabberd_sm ! {route, From, Jid, StampedPacket}
            end,
            lists:keysort(#push_stored_packet.timestamp, Packets)),
        case Packets of
            [] -> ok;
            _ -> mnesia:delete({push_stored_packet, LJid})
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(on_remove_user/2 :: (User :: binary(), Server :: binary()) -> ok).

on_remove_user(User, Server) ->
    F = fun() ->
        case mnesia:read({push_user, {User, Server}}) of
            [] -> ok;
            [#push_user{subscriptions = Subscriptions}] ->
                lists:foreach(
                    fun(#subscription{resource = R}) ->
                        mnesia:delete({push_stored_packet, {User, Server, R}})
                    end,
                    Subscriptions),
                mnesia:delete({push_user, {User, Server}})
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(on_affiliation_removal/4 ::
(
    _User :: jid(),
    From :: jid(),
    To :: jid(),
    Packet :: xmlelement())
    -> ok
).

on_affiliation_removal(User, From, _To,
                       #xmlel{name = <<"message">>, children = Children}) ->
    FindNodeAffiliations =
    fun 
    F([#xmlel{name = <<"pubsub">>, attrs = Attrs, children = PChildr}|T]) ->
        case proplists:get_value(<<"xmlns">>, Attrs) of
            ?NS_PUBSUB ->
                case PChildr of
                    [#xmlel{name = <<"affiliations">>} = A] ->
                        case proplists:get_value(<<"node">>, A#xmlel.attrs) of
                            undefined -> error;
                            Node -> {Node, A#xmlel.children}
                        end;
                    _ -> not_found
                end;
            _ -> F(T)
        end;
    F([_|T]) -> F(T);
    F([]) -> not_found
    end,
    FindJid =
    fun
    F([#xmlel{name = <<"affiliation">>, attrs = Attrs}|T]) ->
        case proplists:get_value(<<"affiliation">>, Attrs) of
            <<"none">> ->
                case proplists:get_value(<<"jid">>, Attrs) of
                    J when is_binary(J) -> jlib:string_to_jid(J);
                    _ -> error
                end;
            undefined -> F(T)
        end;
    F([_|T]) -> F(T);
    F([]) -> not_found
    end,
    ErrMsg =
    fun() ->
        ?INFO_MSG("Received invalid affiliation removal notification from ~p",
                  [jlib:jid_to_string(From)])
    end,
    case FindNodeAffiliations(Children) of
        not_found -> ok;
        error -> ErrMsg();
        {Node, Affiliations} ->
            BareUserJid = jlib:jid_remove_resource(jlib:jid_tolower(User)),
            case FindJid(Affiliations) of
                not_found -> ok;
                BareUserJid -> disable(BareUserJid, From, Node, true);
                _ -> ErrMsg()
            end
    end;

on_affiliation_removal(_Jid, _From, _To, _) -> ok.
        
%-------------------------------------------------------------------------

-spec(on_wait_for_resume/3 ::
(
    Timeout :: integer(),
    jid(),
    UnackedStanzas :: [xmlelement()])
    -> integer()
).

on_wait_for_resume(Timeout, User, UnackedStanzas) ->
    F = fun() -> dispatch(UnackedStanzas, User, true) end,
    case mnesia:transaction(F) of
        {atomic, not_subscribed} -> Timeout;

        {atomic, ok} ->
            ?DEBUG("+++++++ adjusting timeout to ~p",
                   [?ADJUSTED_RESUME_TIMEOUT]),
            ?ADJUSTED_RESUME_TIMEOUT;

        {aborted, Reason} ->
            ?DEBUG("+++++++ mod_push could not read timeout: ~p", [Reason]),
            Timeout
    end.

%-------------------------------------------------------------------------

-spec(on_resume_session/1 ::
(
    User :: jid())
    -> any()
).

on_resume_session(#jid{luser = LUser, lserver = LServer, lresource = LResource}
                  = User) ->
    ?DEBUG("+++++++++++ on_resume_session", []),
    F = fun() ->
        case mnesia:read({push_user, {LUser, LServer}}) of
            [] -> ok;
            [#push_user{subscriptions = Subscrs} = PushUser] ->
                NewSubscrs = set_pending(LResource, false, Subscrs),
                mnesia:write(PushUser#push_user{payload = [],
                                                subscriptions = NewSubscrs}),
                mnesia:delete({push_stored_packet, jlib:jid_tolower(User)}) 
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(incoming_notification/4 ::
(
    _HookAcc :: any(),
    Node :: binary(),
    Payload :: xmlelement(),
    PubOpts :: xmlelement())
    -> any()
).

incoming_notification(_HookAcc, Node, [#xmlel{name = <<"notification">>,
                                              attrs = [{<<"xmlns">>, ?NS_PUSH}],
                                              children = Children}|_],
                      PubOpts) ->
    ?DEBUG("+++++ in mod_push:incoming_notification, Node: ~p, PubOpts = ~p",
           [Node, PubOpts]),
    ProcessReg =
    fun(#push_registration{token = Token,
                           secret = Secret,
                           app_id = AppId,
                           backend_id = BackendId,
                           timestamp = Timestamp}) ->
        case check_secret(Secret, PubOpts) of
            true ->
                case get_xdata_elements(Children) of
                   [] ->
                       do_dispatch_local([], Token, AppId, BackendId, Node,
                                         Timestamp, false);

                    XDataForms ->
                        ParseResult =
                        parse_form(
                            XDataForms, ?NS_PUSH_SUMMARY, [],
                            [{{single, <<"message-count">>},
                              fun erlang:binary_to_integer/1},
                             {{single, <<"last-message-sender">>},
                              fun jlib:string_to_jid/1},
                             {single, <<"last-message-body">>},
                             {{single, <<"pending-subscription-count">>},
                              fun erlang:binary_to_integer/1},
                             {{single, <<"last-subscription-sender">>},
                              fun jlib:string_to_jid/1}]),
                        case ParseResult of
                            {result,
                             [MsgCount, MsgSender, MsgBody, SubscrCount,
                              SubscrSender]} ->
                                Payload =
                                lists:foldl(
                                    fun({Key, Value}, Acc) ->
                                        case Value of
                                            undefined -> Acc;
                                            #jid{} -> jlib:jid_to_string(Value);
                                            _ -> [{Key, Value}|Acc]
                                        end
                                    end,
                                    [],
                                    [{'message-count', MsgCount},
                                     {'last-message-sender', MsgSender},
                                     {'last-message-body', MsgBody},
                                     {'pending-subscription-count', SubscrCount},
                                     {'last-subscription-sender', SubscrSender}]),
                                do_dispatch_local(Payload, Token, AppId,
                                                  BackendId, Node, Timestamp,
                                                  false);
                             Err ->
                                ?DEBUG("+++++ parse_form returned ~p", [Err]),
                                ?INFO_MSG("Cancel dispatching push "
                                          "notification: item published on node"
                                          " ~p contains malformed data form",
                                          [Node]),
                                bad_request
                        end
                end;
 
            false -> not_authorized
        end
    end,
    F = fun() ->
        case mnesia:read({push_registration, Node}) of
            [] ->
                ?INFO_MSG("received push notification for non-existing node ~p",
                          [Node]),
                node_not_found;

            [Reg] ->
                ?DEBUG("+++++ Registration = ~p", [Reg]),
                ProcessReg(Reg)
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, _Reason} -> internal_server_error
    end.

%-------------------------------------------------------------------------

-spec(check_secret/2 ::
(
    Secret :: binary(),
    Opts :: [any()])
    -> boolean()
).

check_secret(Secret, PubOpts) ->
    case proplists:get_value(<<"secret">>, PubOpts) of
        [Secret] -> true;
        _ -> false
    end.

%-------------------------------------------------------------------------

-spec(add_backends/1 ::
(
    Host :: binary())
    -> ok | error
).

add_backends(Host) ->
    CertFile =
    gen_mod:get_module_opt(Host, ?MODULE, certfile,
                           fun(C) when is_binary(C) -> C end,
                           <<"">>),
    BackendOpts =
    gen_mod:get_module_opt(Host, ?MODULE, backends,
                           fun(O) when is_list(O) -> O end,
                           []),
    Backends = parse_backends(BackendOpts, Host, CertFile),
    lists:foreach(
        fun({B, _}) ->
            RegisterHost =B#push_backend.register_host,
            PubsubHost = B#push_backend.pubsub_host,
            ?INFO_MSG("added adhoc command handler for app server ~p",
                      [RegisterHost]),
            ejabberd_hooks:add(node_push_publish_item, PubsubHost, ?MODULE,
                               incoming_notification, 50),
            NewBackend =
            case mnesia:read({push_backend, B#push_backend.id}) of
                [] -> B;
                [#push_backend{cluster_nodes = Nodes}] ->
                    NewNodes =
                    lists:merge(Nodes, B#push_backend.cluster_nodes),
                    B#push_backend{cluster_nodes = NewNodes}
            end,
            mnesia:write(NewBackend)
        end,
        Backends),
    %% remove all tuples {push_backend, auth_data} with duplicate auth_data as
    %% we only need to start one worker for each type / auth_data combination
    RemoveDupAuthData =
    fun F([]) -> [];
        F([{CurB, CurA} | T]) ->
        [{CurB, CurA} | [{B, A} || {B, A} <- F(T), A =/= CurA]]
    end,
    lists:foreach(
        fun({Type, Module}) ->
            MatchingType =
            [{B, A} || {B, A} <- Backends, B#push_backend.type =:= Type],
            start_workers(Host, Module, RemoveDupAuthData(MatchingType))
        end,
        [{apns, ?MODULE_APNS},
         {gcm, ?MODULE_GCM},
         {mozilla, ?MODULE_MOZILLA},
         {ubuntu, ?MODULE_UBUNTU},
         {wns, ?MODULE_WNS}]).
    % TODO:
    % subscribe to mnesia event {table, push_backend, detailed}, so workers can
    % be restarted when backend is updated

%-------------------------------------------------------------------------

-spec(add_disco_hooks/1 ::
(
    ServerHost :: binary())
    -> any()
). 

add_disco_hooks(ServerHost) ->
    BackendKeys = mnesia:all_keys(push_backend),
    lists:foreach(
        fun(K) ->
            [#push_backend{register_host = RegHost,
                           pubsub_host = PubsubHost}] =
            mnesia:read({push_backend, K}),
            case is_local_domain(RegHost) of
                false ->
                    ?DEBUG("Registering new route: ~p", [RegHost]),
                    ejabberd_router:register_route(RegHost);
                true -> ok
            end,
            ejabberd_hooks:add(adhoc_local_commands,
                               RegHost,
                               ?MODULE,
                               process_adhoc_command,
                               75),
            %ejabberd_hooks:add(disco_local_identity, PubsubHost, ?MODULE,
            %                   on_disco_pubsub_identity, 50),
            % FIXME: this is a workaround, see below
            ejabberd_hooks:add(disco_info, ServerHost, ?MODULE,
                               on_disco_pubsub_info, 101),
            ejabberd_hooks:add(disco_local_identity, RegHost, ?MODULE,
                               on_disco_reg_identity, 50),
            ejabberd_hooks:add(disco_sm_identity, ServerHost, ?MODULE,
                               on_disco_sm_identity, 49)
        end,
        BackendKeys).

%-------------------------------------------------------------------------

-spec(start_workers/3 ::
(
    Host :: binary(),
    Module :: atom(),
    [{push_backend(), auth_data()}])
    -> ok
).

% TODO: remove recursion
start_workers(_Host, _Module, []) -> ok;

start_workers(Host, Module,
              [{Backend,
               #auth_data{auth_key = AuthKey,
                          package_sid = PackageSid,
                          certfile = CertFile}}|T]) ->
    Worker = Backend#push_backend.worker,
    BackendSpec =
    {Worker,
     {gen_server, start_link,
      [{local, Worker}, Module, [Host, AuthKey, PackageSid, CertFile], []]},
     permanent, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, BackendSpec),
    start_workers(Host, Module, T).

%-------------------------------------------------------------------------

-spec(notify_previous_users/1 :: (Host :: binary()) -> ok).

notify_previous_users(Host) ->
    MatchHead = #push_user{bare_jid = {'_', Host}, _='_'},
    Users = mnesia:select(push_user, [{MatchHead, [], ['$_']}]),
    lists:foreach(
        fun(#push_user{bare_jid = BareJid,
                       subscriptions = Subscrs,
                       config = Config,
                       payload = Payload}) ->
            lists:foreach(
                fun
                    (#subscription{pending = true,
                                   node = Node,
                                   reg_type = RegType}) ->
                        FilteredPayload = filter_payload(Payload, Config),
                        do_dispatch(RegType, BareJid, Node, FilteredPayload);

                    (_) -> ok
                end,
                Subscrs)
        end,
        Users),
    lists:foreach(fun mnesia:delete_object/1, Users).

%-------------------------------------------------------------------------

-spec(process_adhoc_command/4 ::
(
    Acc :: any(),
    From :: jid(),
    To :: jid(),
    Request :: adhoc_request())
    -> any()
).

process_adhoc_command(Acc, From, #jid{lserver = LServer},
                      #adhoc_request{node = Command,
                                     action = <<"execute">>,
                                     xdata = XData} = Request) ->
    Action = case Command of
        <<"register-push-apns">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>}],
                                    [{single, <<"device-id">>},
                                     {single, <<"device-name">>}]),
                case Parsed of
                    {result, [Base64Token, DeviceId, DeviceName]} ->
                        case catch base64:decode(Base64Token) of
                            {'EXIT', _} ->
                                error;

                            Token ->
                                register_client(From, LServer, apns, Token,
                                                DeviceId, DeviceName, <<"">>)
                        end;

                    _ -> error
                end
            end;

        <<"register-push-gcm">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>}],
                                    [{single, <<"device-id">>},
                                     {single, <<"device-name">>}]),
                case Parsed of
                    {result, [Token, DeviceId, DeviceName]} ->
                        register_client(From, LServer, gcm, Token, DeviceId,
                                        DeviceName, <<"">>);

                    _ -> error
                end
            end;

        <<"register-push-mozilla">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>}],
                                    [{single, <<"device-id">>},
                                     {single, <<"device-name">>}]),
                case Parsed of
                    {result, [Token, DeviceId, DeviceName]} ->
                        register_client(From, LServer, mozilla, Token, DeviceId,
                                        DeviceName, <<"">>);

                    _ -> error
                end
            end;

        <<"register-push-ubuntu">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>},
                                     {single, <<"application-id">>}],
                                    [{single, <<"device-id">>},
                                     {single, <<"device-name">>}]),
                case Parsed of
                    {result, [Token, AppId, DeviceId, DeviceName]} ->
                        register_client(From, LServer, ubuntu, Token,
                                        DeviceId, DeviceName, AppId);
                    
                    _ -> error
                end
            end;

        <<"register-push-wns">> ->
            fun() ->
                Parsed = parse_form([XData],
                                    undefined,
                                    [{single, <<"token">>}],
                                    [{single, <<"device-id">>},
                                     {single, <<"device-name">>}]),
                case Parsed of
                    {result, [Token, DeviceId, DeviceName]} ->
                        register_client(From, LServer, wns, Token, DeviceId,
                                        DeviceName, <<"">>);

                    _ -> error
                end
            end;

        <<"unregister-push">> ->
            fun() ->
                Parsed = parse_form([XData], undefined,
                                    [], [{single, <<"device-id">>},
                                         {multi, <<"nodes">>}]),
                case Parsed of
                    {result, [DeviceId, NodeIds]} -> 
                        unregister_client(From, DeviceId, NodeIds);

                    not_found ->
                        unregister_client(From, undefined, []);

                    _ -> error
                end
            end;

        <<"list-push-registrations">> -> fun() -> list_registrations(From) end;

        _ -> unknown
    end,
    Result = case Action of
        unknown -> unknown;
        _ ->
            Host = remove_subdomain(LServer),
            Access =
            gen_mod:get_module_opt(Host,
                                   ?MODULE,
                                   access_backends,
                                   fun(A) when is_atom(A) -> A end,
                                   all),
            case acl:match_rule(Host, Access, From) of
                deny -> {error, ?ERR_FORBIDDEN};
                allow -> Action()
            end
    end,
    case Result of
        unknown -> Acc;

        {registered, {PubsubHost, Node, Secret}} ->
            JidField = [?VFIELD(<<"jid">>, PubsubHost)],
            NodeField = case Node of
                <<"">> -> [];
                _ -> [?VFIELD(<<"node">>, Node)]
            end,
            SecretField = [?VFIELD(<<"secret">>, Secret)],
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                   attrs = [{<<"xmlns">>, ?NS_XDATA},
                                            {<<"type">>, <<"result">>}],
                                   children =
                                   JidField ++ NodeField ++ SecretField}]},
            adhoc:produce_response(Request, Response);

        {unregistered, ok} ->
            Response =
            #adhoc_response{status = completed, elements = []},
            adhoc:produce_response(Request, Response);

        {unregistered, UnregisteredNodeIds} ->
            Field =
            ?TVFIELD(<<"list-multi">>, <<"nodes">>, UnregisteredNodeIds),
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                    attrs = [{<<"xmlns">>, ?NS_XDATA},
                                             {<<"type">>, <<"result">>}],
                                    children = [Field]}]},
            adhoc:produce_response(Request, Response);

        {registrations, []} ->
            adhoc:produce_response(
                Request,
                #adhoc_response{status = completed, elements = []});

        {registrations, RegList} ->
            Items =
            lists:foldl(
                fun(Reg, ItemsAcc) ->
                    NameField = case Reg#push_registration.device_name of
                        undefined -> [];
                        Name -> [?VFIELD(<<"device-name">>, Name)]
                    end,
                    NodeField =
                    [?VFIELD(<<"node">>, Reg#push_registration.node)],
                    [?ITEM(NameField ++ NodeField) | ItemsAcc]
                end,
                [],
                RegList),
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                   attrs = [{<<"xmlns">>, ?NS_XDATA},
                                            {<<"type">>, <<"result">>}],
                                   children = Items}]},
            adhoc:produce_response(Request, Response);

        error -> {error, ?ERR_BAD_REQUEST};

        {error, Error} -> {error, Error}
    end;

process_adhoc_command(Acc, _From, _To, _Request) ->
    Acc.
     
%-------------------------------------------------------------------------

-spec(process_iq/3 ::
(
    From :: jid(),
    _To :: jid(),
    IQ :: iq())
    -> iq()
).

process_iq(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    JidB = proplists:get_value(<<"jid">>, SubEl#xmlel.attrs),
    Node = proplists:get_value(<<"node">>, SubEl#xmlel.attrs),
    case JidB of
        undefined -> IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        _ ->
            case jlib:string_to_jid(JidB) of
                error ->
                    IQ#iq{type = error, sub_el = [?ERR_JID_MALFORMED, SubEl]};
                
                Jid ->
                    case {Type, SubEl} of
                        {set, #xmlel{name = <<"enable">>,
                                     children = Children}} ->
                            XDataForms = get_xdata_elements(Children),
                            case enable(From, Jid, Node, XDataForms) of
                                {enabled, ok} ->
                                    IQ#iq{type = result, sub_el = []};

                                {enabled, ResponseForm} -> 
                                    NewSubEl =
                                    SubEl#xmlel{children = ResponseForm},
                                    IQ#iq{type = result, sub_el = [NewSubEl]};

                                {error, Error} ->
                                    IQ#iq{type = error,
                                          sub_el = [Error, SubEl]}
                            end;

                        {set, #xmlel{name = <<"disable">>}} ->
                            case disable(From, Jid, Node) of
                                {disabled, ok} ->
                                    IQ#iq{type = result, sub_el = []};

                                {error, Error} ->
                                    IQ#iq{type = error,
                                          sub_el = [Error, SubEl]}
                            end;

                        _ ->
                            ?DEBUG("+++++ Received Invalid push iq from ~p",
                                   [jlib:jid_to_string(From)]),
                            IQ#iq{type = error,
                                  sub_el = [?ERR_NOT_ALLOWED, SubEl]}
                    end
            end
    end.
                    
%-------------------------------------------------------------------------

-spec(on_disco_sm_features/5 ::
(
    Acc :: any(),
    _From :: jid(),
    _To :: jid(),
    Node :: binary(),
    _Lang :: binary())
    -> any()
).

on_disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
    ?DEBUG("+++++++++ on_disco_sm_features, returning ~p",
           [{result, [?NS_PUSH]}]),
    {result, [?NS_PUSH]};

on_disco_sm_features({result, Features}, _From, _To, <<"">>, _Lang) ->
    ?DEBUG("+++++++++ on_disco_sm_features, returning ~p",
           [{result, [?NS_PUSH|Features]}]),
    {result, [?NS_PUSH|Features]};

on_disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    ?DEBUG("+++++++++ on_disco_sm_features, returning ~p", [Acc]),
    Acc.

%%-------------------------------------------------------------------------

% FIXME: this is a workaround, it adds identity and features to the info data
% created by mod_disco when mod_pubsub calls the hook disco_info. Instead
% mod_pubsub should set mod_disco:process_local_iq_info as iq handler for its
% pubsub host. Then on_disco_identity can hook up with disco_local_identity and
% disco_local_features
on_disco_pubsub_info(Acc, _ServerHost, mod_pubsub, <<"">>, <<"">>) ->
    PushIdentity = #xmlel{name = <<"identity">>,
                          attrs = [{<<"category">>, <<"pubsub">>},
                                   {<<"type">>, <<"push">>}],
                          children = []},
    PushFeature = #xmlel{name = <<"feature">>,
                         attrs = [{<<"var">>, ?NS_PUSH}],
                         children = []},
    [PushIdentity, PushFeature | Acc];

on_disco_pubsub_info(Acc, _, _, _, _) ->
    Acc.

%%-------------------------------------------------------------------------

%on_disco_pubsub_identity(Acc, _From, #jid{lserver = PubsubHost}, <<"">>, _) ->
%    F = fun() ->
%        MatchHead = #push_backend{pubsub_host = PubsubHost, _='_'},
%        case mnesia:select(push_backend, [{MatchHead, [], ['$_']}]) of
%            [] -> Acc;
%            _ ->
%                PushIdentity =
%                #xmlel{name = <<"identity">>,
%                       attrs = [{<<"category">>, <<"pubsub">>},
%                                {<<"type">>, <<"push">>}],
%                       children = []},
%                [PushIdentity|Acc]
%        end
%    end,
%    case mnesia:transaction(F) of
%        {atomic, AccOut} -> AccOut;
%        _ -> Acc
%    end;
%
%on_disco_pubsub_identity(Acc, _From, _To, _Node, _Lang) ->
%    Acc.

%%-------------------------------------------------------------------------

-spec(on_disco_reg_identity/5 ::
(
    Acc :: [xmlelement()],
    _From :: jid(),
    To :: jid(),
    _Node :: binary(),
    _Lang :: binary())
    -> [xmlelement()]
).

on_disco_reg_identity(Acc, _From, #jid{lserver = RegHost}, <<"">>, _Lang) ->
    F = fun() ->
        MatchHead =
        #push_backend{register_host = RegHost, app_name = '$1', _='_'},
        mnesia:select(push_backend, [{MatchHead, [], ['$1']}])
    end,
    case mnesia:transaction(F) of
        {atomic, AppNames} ->
            Identities =
            lists:map(
                fun(A) ->
                    AppName = case is_binary(A) of
                        true -> A;
                        false -> <<"any">>
                    end,
                    #xmlel{name = <<"identity">>,
                           attrs = [{<<"category">>, <<"app-server">>},
                                    {<<"type">>, AppName}],
                           children = []}
                end,
                AppNames),
            Identities ++ Acc;

        _ ->
            Acc
    end;

on_disco_reg_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.
               
on_disco_sm_identity(Acc, From, To, <<"">>, _Lang) ->
    FromL = jlib:jid_tolower(From),
    ToL = jlib:jid_tolower(To),
    case jlib:jid_remove_resource(FromL) of
        ToL ->
            F = fun() ->
                case mnesia:read({push_user, {To#jid.luser, To#jid.lserver}}) of
                    [] ->
                        make_config_form(get_global_config(To#jid.lserver)) ++
                        Acc;
                    [#push_user{config = Config}] ->
                        make_config_form(Config) ++ Acc
                end
            end,
            case mnesia:transaction(F) of
                {atomic, Elements} -> Elements;
                _ -> Acc
            end;

        _ -> Acc
    end;

on_disco_sm_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

%-------------------------------------------------------------------------
% gen_mod callbacks
%-------------------------------------------------------------------------

-spec(start/2 ::
(
    Host :: binary(),
    Opts :: [any()])
    -> any()
).

start(Host, _Opts) ->
    % FIXME: is this fixed?
    % FIXME: Currently we're assuming that in a cluster all instances have
    % exactly the same mod_push configuration. This is because we want every
    % instance to be able to serve the same proprietary push backends. The
    % opposite approach would be to partition the backends among the instances.
    % This would make cluster-internal messages necessary, so the current
    % implementation saves traffic. On the downside, config differences
    % between two instances would probably lead to unpredictable results and
    % the authorization data needed for e.g. APNS must be present on all
    % instances 
    % TODO: disable push subscription when session is deleted
    mnesia:create_table(push_user,
                        [{disc_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, push_user)}]),
    mnesia:create_table(push_registration,
                        [{disc_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, push_backend)}]),
    mnesia:create_table(push_backend,
                        [{ram_copies, [node()]},
                         {type, set},
                         {attributes, record_info(fields, push_backend)}]),
    mnesia:create_table(push_stored_packet,
                        [{disc_only_copies, [node()]},
                         {type, bag},
                         {attributes, record_info(fields, push_stored_packet)}]),
    UserFields = record_info(fields, push_user),
    RegFields = record_info(fields, push_registration),
    SPacketFields = record_info(fields, push_stored_packet),
    case mnesia:table_info(push_user, attributes) of
        UserFields -> ok;
        _ -> mnesia:transform_table(push_user, ignore, UserFields)
    end,
    case mnesia:table_info(push_registration, attributes) of
        RegFields -> ok;
        _ -> mnesia:transform_table(push_registration, ignore, RegFields)
    end,
    case mnesia:table_info(push_stored_packet, attributes) of
        SPacketFields -> ok;
        _ -> mnesia:transform_table(push_stored_packet, ignore, SPacketFields)
    end,
    % TODO: check if backends in registrations are still present
    % TODO: send push notifications (event server available) to all push users

    %%% FIXME: haven't thought about IQDisc parameter
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH, ?MODULE,
                                  process_iq, one_queue),
    ejabberd_hooks:add(mgmt_queue_add_hook, Host, ?MODULE, on_store_stanza,
                       50),
    ejabberd_hooks:add(unset_presence_hook, Host, ?MODULE, on_unset_presence,
                       70),
    ejabberd_hooks:add(mgmt_resume_session_hook, Host, ?MODULE,
                       on_resume_session, 50),
    ejabberd_hooks:add(mgmt_wait_for_resume_hook, Host, ?MODULE,
                       on_wait_for_resume, 50),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
                       on_disco_sm_features, 50),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
                       on_affiliation_removal, 50),
    ejabberd_hooks:add(user_available_hook, Host, ?MODULE,
                       resend_packets, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, on_remove_user, 50),
    % FIXME: disco_sm_info is not implemented in mod_disco!
    %ejabberd_hooks:add(disco_sm_info, Host, ?MODULE, on_disco_sm_info, 50),
    F = fun() ->
        add_backends(Host),
        add_disco_hooks(Host),
        notify_previous_users(Host)
    end,
    case mnesia:transaction(F) of
        {atomic, _} -> ?DEBUG("++++++++ Added push backends", []);
        {aborted, Error} -> ?DEBUG("+++++++++ Error adding push backends: ~p", [Error])
    end.

%-------------------------------------------------------------------------

-spec(stop/1 ::
(
    Host :: binary())
    -> any()
).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH),
    ejabberd_hooks:delete(mgmt_queue_add_hook, Host, ?MODULE,
                          on_store_stanza, 50),
    ejabberd_hooks:delete(unset_presence_hook, Host, ?MODULE, on_unset_presence,
                          70),
    ejabberd_hooks:delete(mgmt_resume_session_hook, Host, ?MODULE,
                          on_resume_session, 50),
    ejabberd_hooks:delete(mgmt_wait_for_resume_hook, Host, ?MODULE,
                          on_wait_for_resume, 50),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
                          on_disco_sm_features, 50),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
                          on_affiliation_removal, 50),
    ejabberd_hooks:delete(user_available_hook, Host, ?MODULE,
                          resend_packets, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, on_remove_user, 50),
    % FIXME:
    %ejabberd_hooks:delete(disco_sm_info, Host, ?MODULE, on_disco_sm_info, 50),
    F = fun() ->
        mnesia:foldl(
            fun(Backend) ->
                RegHost = Backend#push_backend.register_host,
                PubsubHost = Backend#push_backend.pubsub_host,
                ejabberd_router:unregister_route(RegHost),
                ejabberd_router:unregister_route(PubsubHost),
                ejabberd_hooks:delete(adhoc_local_commands, RegHost, ?MODULE,
                                      process_adhoc_command, 75),
                ejabberd_hooks:delete(disco_sm_identity, Host, ?MODULE,
                                      on_disco_sm_identity, 49),
                ejabberd_hooks:delete(disco_local_identity, RegHost, ?MODULE,
                                      on_disco_reg_identity, 50),
                ejabberd_hooks:delete(disco_info, Host, ?MODULE,
                                      on_disco_pubsub_info, 50),
                {Local, Remote} =
                lists:partition(fun(N) -> N =:= node() end,
                                Backend#push_backend.cluster_nodes),
                case Local of
                    [] -> ok;
                    _ ->
                        case Remote of
                            [] ->
                                mnesia:delete({push_backend, Backend#push_backend.id});
                            _ ->
                                mnesia:write(
                                    Backend#push_backend{cluster_nodes = Remote})
                        end,
                        supervisor:terminate_child(ejabberd_sup,
                                                   Backend#push_backend.worker)
                end
            end,
            ok,
            push_backends,
            write)
       end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(include_senders) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(include_message_count) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(include_subscription_count) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(include_message_bodies) -> fun(B) when is_boolean(B) -> B end;
mod_opt_type(access_backends) -> fun(A) when is_atom(A) -> A end;
mod_opt_type(certfile) -> fun(B) when is_binary(B) -> B end;
mod_opt_type(backends) -> fun ?MODULE:get_backend_opts/1;
mod_opt_type(_) ->
    [iqdisc, include_senders, include_message_count, include_subscription_count,
     include_message_bodies, access_backends, certfile, backends].

%-------------------------------------------------------------------------
% mod_push utility functions
%-------------------------------------------------------------------------

-spec(get_global_config/1 :: (Host :: binary()) -> user_config()).

get_global_config(Host) ->
    [{'include-senders',
      gen_mod:get_module_opt(Host, ?MODULE, include_senders,
                             fun(B) when is_boolean(B) -> B end,
                             ?INCLUDE_SENDERS_DEFAULT)},
     {'include-message-count',
      gen_mod:get_module_opt(Host, ?MODULE, include_message_count,
                             fun(B) when is_boolean(B) -> B end,
                             ?INCLUDE_MSG_COUNT_DEFAULT)},
     {'include-subscription-count',
      gen_mod:get_module_opt(Host, ?MODULE, include_subscription_count,
                             fun(B) when is_boolean(B) -> B end,
                             ?INCLUDE_SUBSCR_COUNT_DEFAULT)},
     {'include-message-bodies',
      gen_mod:get_module_opt(Host, ?MODULE, include_message_bodies,
                             fun(B) when is_boolean(B) -> B end,
                             ?INCLUDE_MSG_BODIES_DEFAULT)}].

%-------------------------------------------------------------------------

-spec(make_config/3 ::
(
    XDataForms :: [xmlelement()],
    OldConfig :: user_config(),
    ConfigPrivilege :: disable_only | enable_disable)
    -> {user_config(), user_config()}
).

make_config(XDataForms, OldConfig, ConfigPrivilege) ->
    %% if a user is allowed to change an option from OldValue to NewValue,
    %% OptionAllowed(OldValue, NewValue) returns true
    OptionAllowed = case ConfigPrivilege of
        disable_only ->
            fun
                (true, false) -> true;
                (Old, New) when Old =:= New -> true;
                (_, _) -> false
            end;
        enable_disable ->
            fun
                (_, NewValue) when not is_boolean(NewValue) -> false;
                (_, _) -> true
            end
    end,
    AllowedOpts =
    ['include-senders', 'include-message-count', 'include-subscription-count',
     'include-message-bodies'],
    OptionalFields =
    lists:map(
        fun(Opt) -> {{single, atom_to_binary(Opt, utf8)},
                     fun(B) -> {Opt, binary_to_boolean(B, undefined)} end}
        end,
        AllowedOpts),
    ParseResult = parse_form(XDataForms, ?NS_PUSH_OPTIONS, [], OptionalFields),
    case ParseResult of
        error -> error;
        
        not_found -> {OldConfig, []};

        {result, ParsedOptions} ->
            AnyError =
            lists:any(
                fun
                    (error) -> true;
                    (_) -> false
                end,
                ParsedOptions),
            case AnyError of
                true -> error;

                false ->
                    lists:foldl(
                        fun({Key, Value}, {ConfigAcc, AcceptedOptsAcc}) ->
                            OldValue = proplists:get_value(Key, OldConfig),
                            AcceptOpt = OptionAllowed(OldValue, Value),
                            case AcceptOpt of
                                true ->
                                    {[{Key, Value}|ConfigAcc],
                                     [{Key, Value}|AcceptedOptsAcc]};
                                false ->
                                    {[{Key, OldValue}|ConfigAcc],
                                     AcceptedOptsAcc}
                            end
                        end,
                        {[], []},
                        ParsedOptions)
            end
    end.
                    
%-------------------------------------------------------------------------

-spec(parse_backends/3 ::
(
    BackendOpts :: [any()],
    Host :: binary(),
    DefaultCertFile :: binary())
    -> invalid | [{push_backend(), auth_data()}]
).

parse_backends(RawBackendOptsList, Host, DefaultCertFile) ->
    BackendOptsList = get_backend_opts(RawBackendOptsList),
    MakeBackend =
    fun({RegHostJid, PubsubHostJid, Type, AppName, CertFile, AuthKey,
         PackageSid}, Acc) ->
        ChosenCertFile = case is_binary(CertFile) of
            true -> CertFile;
            false -> DefaultCertFile
        end,
        case is_binary(ChosenCertFile) and (ChosenCertFile =/= <<"">>) of
            true ->
                BackendId =
                erlang:phash2({RegHostJid#jid.lserver, Type}),
                AuthData =
                #auth_data{auth_key = AuthKey,
                           package_sid = PackageSid,
                           certfile = ChosenCertFile},
                Worker =
                gen_mod:get_module_proc(
                    Host,
                    combine_to_atom(?MODULE, Type, AuthData)),
                Backend =
                #push_backend{
                   id = BackendId,
                   register_host = RegHostJid#jid.lserver,
                   pubsub_host = PubsubHostJid#jid.lserver,
                   type = Type,
                   app_name = AppName,
                   cluster_nodes = [node()],
                   worker = Worker},
                [{Backend, AuthData}|Acc];

            false ->
                ?ERROR_MSG("option certfile not defined for mod_push backend",
                           []),
                Acc
        end
    end,
    lists:foldl(MakeBackend, [], BackendOptsList).

%-------------------------------------------------------------------------

get_backend_opts(RawOptsList) ->
    lists:map(
        fun(Opts) ->
            RegHostJid =
            jlib:string_to_jid(proplists:get_value(register_host, Opts)),
            PubsubHostJid =
            jlib:string_to_jid(proplists:get_value(pubsub_host, Opts)),
            RawType = proplists:get_value(type, Opts),
            Type =
            case lists:member(RawType, [apns, gcm, mozilla, ubuntu, wns]) of
                true -> RawType
            end,
            AppName = proplists:get_value(app_name, Opts, <<"any">>),
            CertFile = proplists:get_value(certfile, Opts),
            AuthKey = proplists:get_value(auth_key, Opts),
            PackageSid = proplists:get_value(package_sid, Opts),
            {RegHostJid, PubsubHostJid, Type, AppName, CertFile, AuthKey,
             PackageSid}
        end,
        RawOptsList).

%-------------------------------------------------------------------------

-spec(make_payload/3 ::
(
    UnackedStanzas :: [{erlang:timestamp(), xmlelement()}],
    OldPayload :: payload(),
    Config :: user_config())
    -> none | {payload, payload(), [{erlang:timestamp(), xmlelement()}]}
).

make_payload(UnackedStanzas, StoredPayload, Config) ->
    StanzaToPayload =
    fun({_Timestamp, Stanza}, OldPayload) ->
	    FromS = proplists:get_value(<<"from">>, Stanza#xmlel.attrs),
        case Stanza of
            #xmlel{name = <<"message">>, children = Children} ->
                %% FIXME: Do we want to send push notifications on every message type?
                %% FIXME: what about multiple body elements for different languages?
                %% FIXME: max length of body's cdata?
                BodyPred =
                fun (#xmlel{name = <<"body">>}) -> true;
                    (_) -> false
                end,
                MsgBody = case lists:filter(BodyPred, Children) of
                    [] -> <<"">>;
                    [#xmlel{children = [{xmlcdata, CData}]}|_] -> CData
                end,
                OldMsgCount = proplists:get_value('message-count', OldPayload, 0),
                MsgCount = case OldMsgCount of
                    ?MAX_INT -> 0; 
                    C when is_integer(C) -> C + 1
                end,
                [{'message-count', MsgCount},
                 {'last-message-sender', FromS},
                 {'last-message-body', MsgBody}];
             
           #xmlel{name = <<"presence">>, attrs = Attrs} -> 
                case proplists:get_value(<<"type">>, Attrs) of
                    <<"subscribe">> ->
                        OldSubscrCount =
                        proplists:get_value('pending-subscription-count',
                                            OldPayload, 0),
                        SubscrCount =
                        case OldSubscrCount of
                            ?MAX_INT -> 0;
                            C when is_integer(C) -> C + 1
                        end,
                        [{'pending-subscription-count', SubscrCount},
                         {'last-subscription-sender', FromS}];
                   
                    _ -> none
                end;

            _ -> none
        end
    end,
    
    Result =
    lists:foldl(
        fun(Stanza, {PayloadAcc, StanzasAcc}) ->
            case StanzaToPayload(Stanza, PayloadAcc) of
                none -> {PayloadAcc, StanzasAcc};
                P -> {P, [Stanza|StanzasAcc]}
            end
        end,
        {StoredPayload, []},
        UnackedStanzas),
    case Result of
        {_, []} -> none;
        {Payload, StanzasToStore} ->
            {payload, filter_payload(Payload, Config), StanzasToStore}
    end.

%-------------------------------------------------------------------------

-spec(filter_payload/2 ::
(
    Payload :: payload(),
    Config :: user_config())
    -> payload()
).

filter_payload(Payload, Config) ->
    OptsConfigMapping =
    [{'message-count', 'include-message-count'},
     {'last-message-sender', 'include-senders'},
     {'last-subscription-sender', 'include-senders'},
     {'last-message-body', 'include-message-bodies'},
     {'pending-subscription-count', 'include-subscription-count'}],
    lists:filter(
        fun({Key, _}) ->
            ConfigOpt = proplists:get_value(Key, OptsConfigMapping),
            proplists:get_value(ConfigOpt, Config)
        end,
        Payload).

%-------------------------------------------------------------------------

-spec(set_pending/3 ::
(
    Resource :: binary(),
    NewVal :: boolean(),
    Subscrs :: [subscription()])
    -> [subscription()]
).

set_pending(Resource, NewVal, Subscrs) ->
    {MatchingSubscr, NotMatchingSubscrs} =
    lists:partition(
        fun(S) -> S#subscription.resource =:= Resource end,
        Subscrs),
    case MatchingSubscr of
        [] -> Subscrs;
        [S] -> [S#subscription{pending = NewVal}|NotMatchingSubscrs]
    end.

%-------------------------------------------------------------------------
% general utility functions
%-------------------------------------------------------------------------

-spec(is_local_domain/1 :: (Hostname :: binary()) -> boolean()).

is_local_domain(Hostname) ->
    lists:member(Hostname, ejabberd_router:dirty_get_all_domains()).

%-------------------------------------------------------------------------

-spec(remove_subdomain/1 :: (Hostname :: binary()) -> binary()).

remove_subdomain(Hostname) ->
    Dots = binary:matches(Hostname, <<".">>),
    case length(Dots) of
        NumberDots when NumberDots > 1 ->
            {Pos, _} = lists:nth(NumberDots - 1, Dots),
            binary:part(Hostname, {Pos + 1, byte_size(Hostname) - Pos - 1});
        _ -> Hostname
    end.

%-------------------------------------------------------------------------

vvaluel(Val) ->
    case Val of
        <<>> -> [];
        _ -> [?VVALUE(Val)]
    end.

get_xdata_elements(Elements) ->
    get_xdata_elements(Elements, []).

get_xdata_elements([#xmlel{name = <<"x">>, attrs = Attrs} = H | T], Acc) ->
    case proplists:get_value(<<"xmlns">>, Attrs) of
        ?NS_XDATA -> get_xdata_elements(T, [H|Acc]);
        _ -> get_xdata_elements(T, Acc)
    end;

get_xdata_elements([_ | T], Acc) ->
    get_xdata_elements(T, Acc);

get_xdata_elements([], Acc) ->
    lists:reverse(Acc).

%-------------------------------------------------------------------------

-spec(get_xdata_value/2 ::
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}])
    -> error | binary()
).

get_xdata_value(FieldName, Fields) ->
    get_xdata_value(FieldName, Fields, undefined).

-spec(get_xdata_value/3 ::
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}],
    DefaultValue :: any())
    -> any()
).

get_xdata_value(FieldName, Fields, DefaultValue) ->
    case proplists:get_value(FieldName, Fields, [DefaultValue]) of
        [Value] -> Value;
        _ -> error
    end.

-spec(get_xdata_values/2 ::
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}])
    -> [binary()] 
).

get_xdata_values(FieldName, Fields) ->
    get_xdata_values(FieldName, Fields, []).

-spec(get_xdata_values/3 ::
(
    FieldName :: binary(),
    Fields :: [{binary(), [binary()]}],
    DefaultValue :: any())
    -> any()
).

get_xdata_values(FieldName, Fields, DefaultValue) ->
    proplists:get_value(FieldName, Fields, DefaultValue).
    
%-------------------------------------------------------------------------

-spec(parse_form/4 ::
(
    [false | xmlelement()],
    FormType :: binary(),
    RequiredFields :: [{multi, binary()} | {single, binary()} |
                       {{multi, binary()}, fun((binary()) -> any())} |
                       {{single, binary()}, fun((binary()) -> any())}],
    OptionalFields :: [{multi, binary()} | {single, binary()} |
                       {{multi, binary()}, fun((binary()) -> any())} |
                       {{single, binary()}, fun((binary()) -> any())}])
    -> not_found | error | {result, [any()]} 
).

parse_form([], _FormType, _RequiredFields, _OptionalFields) ->
    not_found;

parse_form([false|T], FormType, RequiredFields, OptionalFields) ->
    parse_form(T, FormType, RequiredFields, OptionalFields);

parse_form([XDataForm|T], FormType, RequiredFields, OptionalFields) ->
    case jlib:parse_xdata_submit(XDataForm) of
        invalid -> parse_form(T, FormType, RequiredFields, OptionalFields);
        Fields ->
            case get_xdata_value(<<"FORM_TYPE">>, Fields) of
                FormType ->
                    GetValues =
                    fun
                        ({multi, Key}) -> get_xdata_values(Key, Fields);
                        ({single, Key}) -> get_xdata_value(Key, Fields);
                        ({KeyTuple, Convert}) ->
                            case KeyTuple of
                                {multi, Key} ->
                                    Values = get_xdata_values(Key, Fields),
                                    Converted = lists:foldl(
                                        fun
                                        (_, error) -> error;
                                        (undefined, Acc) -> [undefined|Acc];
                                        (B, Acc) ->
                                            try [Convert(B)|Acc]
                                            catch error:badarg -> error
                                            end
                                        end,
                                        [],
                                        Values),
                                    lists:reverse(Converted);

                                {single, Key} ->
                                    case get_xdata_value(Key, Fields) of
                                        error -> error;
                                        undefined -> undefined;
                                        Value ->
                                           try Convert(Value)
                                           catch error:badarg -> error
                                           end
                                    end
                            end
                    end,
                    RequiredValues = lists:map(GetValues, RequiredFields),
                    OptionalValues = lists:map(GetValues, OptionalFields),
                    RequiredOk =
                    lists:all(
                        fun(V) ->
                            (V =/= undefined) and (V =/= []) and (V =/= error)
                        end,
                        RequiredValues),
                    OptionalOk =
                    lists:all(fun(V) -> V =/= error end, OptionalValues),
                    case RequiredOk and OptionalOk of
                        false -> error;
                        true ->
                            {result, RequiredValues ++ OptionalValues}
                    end;

                _ -> parse_form(T, FormType, RequiredFields, OptionalFields)
            end
    end.

%-------------------------------------------------------------------------

-spec(make_config_form/1 :: (user_config()) -> [xmlelement()]).

make_config_form(Opts) ->
    Fields =
    [?TVFIELD(<<"boolean">>, atom_to_binary(K, utf8), [boolean_to_binary(V)]) ||
     {K, V} <- Opts],
    case Fields of
        [] -> [];
        _ ->
            [#xmlel{name = <<"x">>,
                    attrs = [{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"result">>}],
                    children = [?HFIELD(?NS_PUSH_OPTIONS)|Fields]}]
    end.

%-------------------------------------------------------------------------

-spec(boolean_to_binary/1 :: (Bool :: boolean()) -> binary()).

boolean_to_binary(Bool) ->
    case Bool of
        true -> <<"1">>;
        false -> <<"0">>
    end.

-spec(binary_to_boolean/2 ::
(
    Binary :: binary(),
    DefaultResult :: any())
    -> any()
).

binary_to_boolean(Binary, DefaultResult) ->
    binary_to_boolean(Binary, DefaultResult, error).

-spec(binary_to_boolean/3 ::
(
    Binary :: binary(),
    DefaultResult :: any(),
    InvalidResult :: any())
    -> any()
).

binary_to_boolean(Binary, DefaultResult, InvalidResult) ->
    case Binary of
        <<"1">> -> true;
        <<"0">> -> false;
        <<"true">> -> true;
        <<"false">> -> false;
        undefined -> DefaultResult;
        _ -> InvalidResult
    end.

%-------------------------------------------------------------------------

-spec(combine_to_atom/3 ::
(
    Atom1 :: atom(),
    Atom2 :: atom(),
    Term :: any())
    -> atom()
).

combine_to_atom(Atom1, Atom2, Term) ->
    TermHash = erlang:phash2(Term),
    List =
    atom_to_list(Atom1) ++ "_" ++ atom_to_list(Atom2) ++ "_" ++
    integer_to_list(TermHash),
    list_to_atom(List).

%-------------------------------------------------------------------------

-spec(ljid_to_jid/1 ::
(
    ljid())
    -> jid()
).

ljid_to_jid({LUser, LServer, LResource}) ->
    #jid{user = LUser, server = LServer, resource = LResource,
         luser = LUser, lserver = LServer, lresource = LResource}.
