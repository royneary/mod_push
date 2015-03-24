%%%----------------------------------------------------------------------
%%% File    : mod_push.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : Send push notifications to client when stanza is stored
%%%           for later delivery
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

%%% implements XEP-0357 Push
%%% global options:
%%% {backends, [list_of_services]} 
%%% config options per proprietary push service:
%%% {host, binary()}
%%% {type, gcm | apns | ubuntu | wns | binary()}
%%% {client, binary()}
%%% {include_senders, true|false} (default: false)
%%% {include_message_count, true|false}
%%% {auth_key, "string"} (default: "")
%%% {certfile, "path/to/cert"}
%%% {silent_push, true|false}
%%% e.g.:
%%% mod_push:
%%%     include_senders: false
%%%     silent_push : true
%%%     backends:
%%%         -
%%%             register_host: "chatninja.org"
%%%             pubsub_host: "push-gcm.chatninja.org"
%%%             type: gcm
%%%             app_name: "chatninja"
%%%             auth_key: "ABCDEFG"
%%%         -
%%%             host: "push-apns.chatninja.org"
%%%             type: apns
%%%             app_name: "chatninja"
%%%             include_senders: true
%%%             certfile: "/etc/jabber/apns_cert.pem"
%%%         -
%%%             host: "push-up.chatninja.org"
%%%             type: up
% TODO: more push events:
% - stream errors,
% - server available (after restart),
% - session terminates (sm_remote_connection_hook)
% TODO: subscribe to event {mnesia_down, Node}, to clean nodes from
% backends' cluster_nodes lists; when no nodes are left, a backend
% and all users registered on it have to be deleted!

-module(mod_push).

-author('christian@rechenwerk.net').

-behaviour(gen_mod).

-export([start/2, stop/1,
         process_iq/3,
         on_store_stanza/3,
         incoming_notification/2,
         on_resend_stanzas/1,
         on_disco_sm_features/5,
         on_disco_pubsub_identity/5,
         on_disco_reg_identity/5,
         process_adhoc_command/4,
         adjust_resume_timeout/2,
         delete_registration/2]).

%-include("ns.hrl").
%-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("adhoc.hrl").

-define(MODULE_APNS, mod_push_apns).
-define(MODULE_GCM, mod_push_gcm).
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

-record(user_config,
        {include_senders :: boolean(),
         include_message_count :: boolean(),
         include_subscription_count :: boolean(),
         include_message_bodies :: boolean()}).

-record(auth_data,
        {auth_key = <<"">> :: binary(),
         certfile = <<"">> :: binary()}).

-record(payload_record,
        {message_count :: integer(),
         last_message_sender :: ljid(),
         last_message_body :: binary(),
         pending_subscription_count :: integer(),
         last_subscription_sender :: ljid()}).

-record(subscription, {resource :: binary(),
                       node :: binary(),
                       reg_type :: reg_type()}).
                       %timestamp = os:timestamp() :: erlang:timestamp()}).

-record(push_user, {bare_jid :: {binary(), binary()},
                    subscriptions :: [subscription()],
                    config :: user_config(),
                    payload :: payload_record()}).

-record(push_registration, {id :: {{binary(), binary()}, binary()}, %% {bare_jid, device_id}
                            node :: binary(),
                            device_name :: binary(),
                            token :: binary(),
                            secret :: binary(),
                            app_id :: binary(),
                            backend_id :: integer(),
                            silent_push :: boolean(),
                            timestamp = now() :: erlang:timestamp()}).

-record(push_backend,
        {id :: integer(),
         register_host :: binary(),
         pubsub_host :: binary(),
         type :: backend_type(),
         app_name :: binary(),
         cluster_nodes = [] :: [atom()],
         worker :: binary()}).

-type user_config() :: #user_config{}.
-type auth_data() :: #auth_data{}.
-type payload_record() :: #payload_record{}.
-type notification_payload() :: [{payload_key(), binary()|integer()}].
-type backend_type() :: apns | gcm | ubuntu | wns.
-type payload_key() ::
    last_message_sender | last_subscription_sender | message_count |
    pending_subscription_count | last_message_body.
-type subscription() :: #subscription{}.
-type reg_type() :: {local_reg, binary()} | % pubsub host
                    {remote_reg, ljid(), binary()}.  % pubsub host, secret
%-type push_user() :: #push_user{}.
%-type push_registration() :: #push_registration{}.
-type push_backend() :: #push_backend{}.

%-------------------------------------------------------------------------

parse_backends([], _Host, _CertFile, Acc) ->
    Acc;

parse_backends([BackendOpts|T], Host, CertFile, Acc) ->
    Type = proplists:get_value(type, BackendOpts),
    RegisterHostB = proplists:get_value(register_host, BackendOpts),
    PubsubHostB = proplists:get_value(pubsub_host, BackendOpts),
    RegisterHostJid = jlib:string_to_jid(RegisterHostB),
    PubsubHostJid = jlib:string_to_jid(PubsubHostB),
    case {RegisterHostJid, PubsubHostJid} of
        {#jid{luser = <<"">>, lserver = RegisterHost, lresource = <<"">>},
         #jid{luser = <<"">>, lserver = PubsubHost, lresource = <<"">>}} ->
            case Type of
               ValidType when ValidType =:= up ->
                    AppName =
                    proplists:get_value(app_name, BackendOpts),
                    BackendId =
                    erlang:phash2({RegisterHost, PubsubHost, Type, AppName}),
                    AuthData =
                    #auth_data{
                        auth_key = proplists:get_value(auth_key, BackendOpts),
                        certfile =
                        proplists:get_value(certfile, BackendOpts, CertFile)},
                    Worker =
                    gen_mod:get_module_proc(
                        Host,
                        combine_to_atom(?MODULE, Type, AuthData)), 
                    Backend =
                    #push_backend{
                        id = BackendId,
                        register_host = RegisterHost,
                        pubsub_host = PubsubHost,
                        type = Type,
                        app_name = AppName,
                        worker = Worker
                    },
                    parse_backends(T, Host, CertFile, [{Backend, AuthData}|Acc]);

                NotYetImplemented when NotYetImplemented =:= apns;
                                       NotYetImplemented =:= gcm;
                                       NotYetImplemented =:= wns ->
                    ?INFO_MSG("push backend type ~p not implemented yet",
                              [atom_to_list(NotYetImplemented)]),
                    invalid;

                _ ->
                    ?INFO_MSG("unknown push backend type for pubsub host ~p",
                              [PubsubHost]),
                    invalid
            end;

        {error, _} ->
            ?INFO_MSG("push backend has invalid register host ~p",
                      [RegisterHostB]),
            invalid;

        {_, error} ->
            ?INFO_MSG("push backend has invalid pubsub host ~p",
                      [PubsubHostB]),
            invalid
    end.

%-------------------------------------------------------------------------

get_certfile(Opts) ->
    case catch iolist_to_binary(proplists:get_value(certfile, Opts)) of
	Filename when is_binary(Filename), Filename /= <<"">> ->
	    Filename;
	_ ->
	    undefined
    end.

%-------------------------------------------------------------------------

%% data form helpers (copied from mod_announce)
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

-define(HFIELD(Val), ?TVFIELD(<<"hidden">>, <<"FORM_TYPE">>, Val)).

-define(ITEM(Fields),
(
    #xmlel{name = <<"item">>,
           children = Fields}
)).


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

-spec(make_payload_record/3 ::
(
    From :: jid(),
    Stanza :: xmlelement(),
    OldRecord :: payload_record())
    -> payload_record()
).

make_payload_record(From, Stanza, OldRecord) ->
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
            MsgCount = case OldRecord#payload_record.message_count of
                ?MAX_INT -> 0; 
                OldMsgCount when is_integer(OldMsgCount) -> OldMsgCount + 1;
                _ -> 1
            end,
            OldRecord#payload_record{
                message_count = MsgCount,
                last_message_sender = jlib:jid_to_string(From),
                last_message_body = MsgBody};
         
        #xmlel{name = <<"presence">>, attrs = Attrs} -> 
            case proplists:get_value(<<"type">>, Attrs) of
                <<"subscribe">> ->
                    SubscrCount =
                    case OldRecord#payload_record.pending_subscription_count of
                        ?MAX_INT -> 0;
                        OldSubscrCount when is_integer(OldSubscrCount) ->
                            OldSubscrCount + 1;
                        _ -> 1
                    end,
                    OldRecord#payload_record{
                        pending_subscription_count = SubscrCount,
                        last_subscription_sender = jlib:jid_to_string(From)};

                _ -> OldRecord
            end;

        _ -> OldRecord
    end.

%-------------------------------------------------------------------------

-spec(make_payload/1 ::
(
    Payload :: payload_record())
    -> [{atom(), binary()|integer()}]
).

make_payload(PayloadRecord) ->
    IncludeAllConfig =
    #user_config{include_senders = true,
                 include_message_count = true,
                 include_subscription_count = true,
                 include_message_bodies = true},
    make_payload(PayloadRecord, IncludeAllConfig).

%-------------------------------------------------------------------------

-spec(make_payload/2 ::
(
    Payload :: payload_record(),
    Config :: user_config())
    -> [{atom(), binary()|integer()}]
).

make_payload(#payload_record{message_count = MsgCount,
                             last_message_sender = MsgSender,
                             last_message_body = MsgBody,
                             pending_subscription_count = SubscrCount,
                             last_subscription_sender = SubscrSender},
             #user_config{include_senders = IncSenders,
                          include_message_count = IncMsgCount,
                          include_subscription_count = IncSubscrCount,
                          include_message_bodies = IncMsgBodies}) ->
    IncludeIfOption =
    fun
        F({Option, [{K, V}|T]}, AccIn) ->
            AccOut = case Option of
                false -> AccIn;
                true ->
                    case V of
                       undefined -> AccIn;
                       _ -> [{K, V}|AccIn]
                    end
            end,
            F({Option, T}, AccOut); 

        F({_, []}, AccIn) -> AccIn
    end,
    lists:foldl(
        IncludeIfOption,
        [],
        [{IncSenders, [{last_message_sender, MsgSender},
                       {last_subscription_sender, SubscrSender}]},
         {IncMsgCount, [{message_count, MsgCount}]},
         {IncSubscrCount, [{pending_subscription_count, SubscrCount}]},
         {IncMsgBodies, [{last_message_body, MsgBody}]}]).

%-------------------------------------------------------------------------

boolean_to_binary(Bool) ->
    case Bool of
        true -> <<"1">>;
        false -> <<"0">>
    end.

binary_to_boolean(Binary, DefaultResult) ->
    binary_to_boolean(Binary, DefaultResult, error).

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

get_xdata_value(FieldName, Fields) ->
    get_xdata_value(FieldName, Fields, undefined).

get_xdata_value(FieldName, Fields, DefaultValue) ->
    case proplists:get_value(FieldName, Fields, [DefaultValue]) of
        [Value] -> Value;
        _ -> error
    end.

get_xdata_values(FieldName, Fields) ->
    get_xdata_value(FieldName, Fields, []).

get_xdata_values(FieldName, Fields, DefaultValue) ->
    proplists:get_value(FieldName, Fields, DefaultValue).
    
%-------------------------------------------------------------------------

parse_form([], _FormType, _RequiredFields, _OptionalFields) ->
    not_found;

parse_form([XDataForm|T], FormType, RequiredFields, OptionalFields) ->
    case jlib:parse_xdata_submit(XDataForm) of
        invalid ->
            parse_form(T, FormType, RequiredFields, OptionalFields);
        Fields ->
            GetValues =
                fun
                ({Key, Convert}) ->
                    case Key of
                        {multi, Key} ->
                            Values = get_xdata_values(Key, Fields),
                            Converted = lists:foldl(
                                fun
                                (_, error) -> error;
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
                                undefined -> undefined;
                                error -> error;
                                Value ->
                                   try Convert(Value)
                                   catch error:badarg -> error
                                   end
                            end
                    end;

                (Key) ->
                    case Key of
                        {multi, Key} -> get_xdata_values(Key, Fields);
                        {single, Key} ->  get_xdata_value(Key, Fields)
                    end
            end,
            case get_xdata_value(<<"FORM_TYPE">>, Fields) of
                FormType ->
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

-spec(register_client/8 ::
(
    User :: jid(),
    RegisterHost :: binary(),
    Type :: backend_type(),
    Token :: binary(),
    DeviceId :: binary(),
    DeviceName :: binary(),
    AppId :: binary(),
    Silent :: boolean())
    -> {registered,
        PubsubHost :: binary(),
        Node :: binary(),
        Secret :: binary()}
).

register_client(#jid{lresource = <<"">>}, _, _, _, <<"">>, _, _, _) ->
    error;

register_client(#jid{lresource = <<"">>}, _, _, _, undefined, _, _, _) ->
    error;

register_client(#jid{luser = LUser,
                     lserver = LServer,
                     lresource = LResource} = User,
                RegisterHost, Type, Token, DeviceId, DeviceName, AppId,
                Silent) ->
    F = fun() ->
        MatchHeadBackend =
        #push_backend{register_host = RegisterHost, type = Type, _='_'},
        MatchingBackends =
        mnesia:select(push_backend, [{MatchHeadBackend, [], ['$_']}]),
        case MatchingBackends of
            %% FIXME: there might be type = apns, but app_name chatninja1 AND 
            %% chatninja2!
            [#push_backend{id = BackendId, pubsub_host = PubsubHost}|_] ->
                ChosenDeviceId = case DeviceId of
                    <<"">> -> LResource;
                    _ -> DeviceId
                end,
                ExistingReg =
                mnesia:read({push_registration,
                             {{LUser, LServer}, ChosenDeviceId}}),
                Registration =
                case ExistingReg of
                    [] ->
                        Secret = randoms:get_string(),
                        NewNode = randoms:get_string(), 
                        {result, NodeIdx} =
                        mod_pubsub:create_node(RegisterHost, PubsubHost,
                                               NewNode, PubsubHost, <<"push">>),
                        % FIXME: affiliation must be publish-only!
                        mod_pubsub:node_action(PubsubHost, <<"push">>,
                                               set_affiliation,
                                               [NodeIdx, User, publisher]), 
                        #push_registration{id = {{LUser, LServer}, ChosenDeviceId},
                                           node = NewNode,
                                           device_name = DeviceName,
                                           token = Token,
                                           secret = Secret,
                                           app_id = AppId,
                                           backend_id = BackendId,
                                           silent_push = Silent};

                    [OldReg] ->
                        OldReg#push_registration{device_name = DeviceName,
                                                 token = Token,
                                                 app_id = AppId,
                                                 backend_id = BackendId,
                                                 silent_push = Silent,
                                                 timestamp = now()}
                end,
                mnesia:write(Registration),
                {PubsubHost, Registration#push_registration.node,
                 Registration#push_registration.secret};
            
            _ -> error
        end
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> error;
        {atomic, Result} -> {registered, Result}
    end. 
                                         
%-------------------------------------------------------------------------

get_global_config(Host) ->
   #user_config{
        include_senders =
        gen_mod:get_module_opt(Host, ?MODULE, include_senders,
                               fun(B) when is_boolean(B) -> B end,
                               ?INCLUDE_SENDERS_DEFAULT),
        include_message_count =
        gen_mod:get_module_opt(Host, ?MODULE, include_message_count,
                               fun(B) when is_boolean(B) -> B end,
                               ?INCLUDE_MSG_COUNT_DEFAULT),
        include_subscription_count =
        gen_mod:get_module_opt(Host, ?MODULE, include_subscription_count,
                               fun(B) when is_boolean(B) -> B end,
                        ?INCLUDE_SUBSCR_COUNT_DEFAULT),
        include_message_bodies =
        gen_mod:get_module_opt(Host, ?MODULE, include_message_bodies,
                               fun(B) when is_boolean(B) -> B end,
                               ?INCLUDE_MSG_BODIES_DEFAULT)}.

%-------------------------------------------------------------------------

-spec(make_config/3 ::
(
    XDataForms :: [xmlelement()],
    DefConfig :: user_config(),
    ConfigPrivilege :: disable_only | enable_disable)
    -> {user_config(), xmlelement()}
).

make_config(XDataForms,
            #user_config{include_senders = DefIncSenders,
                         include_message_count = DefIncMsgCount,
                         include_subscription_count = DefIncSubscrCount,
                         include_message_bodies = DefIncMsgBodies} = DefConfig,
            ConfigPrivilege) ->
    %% if a user is allowed to change an option and ,
    %% OptionAllowed(OldValue, NewValue) returns true
    OptionAllowed = case ConfigPrivilege of
        disable_only ->
            fun
                (true, false) -> true;
                (_, _) -> false
            end;
        enable_disable ->
            fun
                (_, NewValue) when not is_boolean(NewValue) -> false;
                (_, _) -> true
            end
    end,
    OptionalFields =
    lists:map(
        fun(F) -> {{single, F},
                   fun(B) -> {F, binary_to_boolean(B, undefined)} end}
        end,
        [<<"include-senders">>, <<"include-message-count">>,
         <<"include-subscription-count">>, <<"include-message-bodies">>]),
    ParseResult = parse_form(XDataForms, ?NS_PUSH_OPTIONS, [], OptionalFields),
    case ParseResult of
        error -> error;

        not_found -> {DefConfig, []};

        {result, ParsedTupleList} ->
            AnyError = lists:any(
                fun
                    ({_, error}) -> true;
                    (_) -> false
                end,
                ParsedTupleList),
            case AnyError of
                true ->
                    error;

                false ->
                    [{_, IncSenders}, {_, IncMsgCount}, {_, IncSubscrCount},
                     {_, IncMsgBodies}] = ParsedTupleList,
                    Config =
                    #user_config{
                        include_senders =
                        case OptionAllowed(DefIncSenders, IncSenders) of
                            true -> IncSenders;
                            false -> DefIncSenders
                        end,
                        include_message_count =
                        case OptionAllowed(DefIncMsgCount, IncMsgCount) of
                            true -> IncMsgCount;
                            false -> DefIncMsgCount
                        end,
                        include_subscription_count =
                        case OptionAllowed(DefIncSubscrCount, IncSubscrCount) of
                            true -> IncSubscrCount;
                            false -> DefIncSubscrCount
                        end,
                        include_message_bodies =
                        case OptionAllowed(DefIncMsgBodies, IncMsgBodies) of
                            true -> IncMsgBodies;
                            false -> DefIncMsgBodies
                        end},
                        ChangedOptsFields =
                        lists:filtermap(
                            fun({OldValue, {Opt, NewValue}}) ->
                               case OptionAllowed(OldValue, NewValue) of
                                    true ->
                                        {true,
                                         ?TVFIELD(<<"boolean">>, Opt,
                                                  [boolean_to_binary(NewValue)])};
                                    false -> false
                                end
                            end,
                            lists:zip([DefIncSenders, DefIncMsgCount,
                                       DefIncSubscrCount, DefIncMsgBodies],
                                      ParsedTupleList)),
                        ResponseForm = 
                        [#xmlel{
                            name = <<"x">>,
                            attrs = [{<<"xmlns">>, ?NS_XDATA},
                                     {<<"type">>, <<"result">>}],
                            children =
                            [?HFIELD(?NS_PUSH_OPTIONS)|ChangedOptsFields]}],
                        {Config, ResponseForm}
            end
    end.

%-------------------------------------------------------------------------

enable(_From, _Jid, undefined, _XData) ->
    {error, ?ERR_NOT_ACCEPTABLE};

enable(_From, _Jid, <<"">>, _XData) ->
    {error, ?ERR_NOT_ACCEPTABLE};

enable(#jid{luser = LUser, lserver = LServer, lresource = LResource},
       #jid{lserver = PubsubHost} = Jid, Node, XDataForms) ->
    ParsedSecret =
    parse_form(XDataForms, ?NS_PUBLISH_OPTIONS, [], [{single, <<"secret">>}]),
    Secret = case ParsedSecret of
        error -> undefined;
        [S] -> S
    end,
    case Secret of
        error -> {error, ?ERR_BAD_REQUEST}; 
        _ ->
            F = fun() ->
                MatchHeadBackend =
                #push_backend{id = '$1', pubsub_host = PubsubHost},
                RegType =
                case mnesia:select(push_backend, [{MatchHeadBackend, [], ['$1']}]) of
                    [] -> {remote_reg, jlib:jid_tolower(Jid), Secret};
                    _ -> {local_reg, PubsubHost}
                end,
                Subscr =
                #subscription{resource = LResource,
                              node = Node,
                              reg_type = RegType},
                case mnesia:read({push_user, {LUser, LServer}}) of
                    [] ->
                        GConfig = get_global_config(LServer),
                        case make_config(XDataForms, GConfig, disable_only) of
                            error -> error;
                            {Config, ResponseForm} ->
                                NewUser =
                                #push_user{bare_jid = {LUser, LServer},
                                           subscriptions = [Subscr],
                                           config = Config,
                                           payload = #payload_record{}},
                                mnesia:write(NewUser),
                                ResponseForm
                        end;
                    
                    [#push_user{subscriptions = Subscriptions,
                                config = OldConfig}] ->
                        case make_config(XDataForms, OldConfig, disable_only) of
                            error -> error;
                            {Config, ResponseForm} -> 
                                FilterNode =
                                fun
                                    (S) when S#subscription.node =:= Node -> false;
                                    (_) -> true
                                end,
                                NewSubscriptions =
                                [Subscr|lists:filter(FilterNode, Subscriptions)],
                                NewUser =
                                #push_user{bare_jid = {LUser, LServer},
                                           subscriptions = NewSubscriptions,
                                           config = Config,
                                           payload = #payload_record{}},
                                mnesia:write(NewUser),
                                ResponseForm
                        end
                end
            end,
            case mnesia:transaction(F) of
                {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
                {atomic, error} -> {error, ?ERR_NOT_ACCEPTABLE};
                {atomic, []} -> {enabled, ok};
                {atomic, ResponseForm} -> {enabled, ResponseForm}
            end
    end.
                
%-------------------------------------------------------------------------

% FIXME: delete User when no Subscriptions are left?

disable(_From, _Jid, <<"">>) ->
    {error, ?ERR_NOT_ACCEPTABLE};

disable(#jid{luser = LUser, lserver = LServer},
        #jid{lserver = PubsubHost} = Jid, Node) ->
    LJid = jlib:jid_tolower(Jid),
    F = fun() ->
        case mnesia:read({push_user, {LUser, LServer}}) of
            [] -> error;
            [#push_user{subscriptions = Subscriptions} = User] ->
                SubscriptionPred =
                fun
                    (NodePred, Subscr) when Subscr#subscription.node =:= NodePred,
                                            Subscr#subscription.reg_type =:=
                                            {local_reg, PubsubHost} ->
                        true;
                    (NodePred, Subscr) when Subscr#subscription.node =:= NodePred,
                                            Subscr#subscription.reg_type =:=
                                            {remote_reg, LJid, '_'} ->
                        true;
                    (_, _) -> false
                end,
                NodeArg = case Node of
                    undefined -> '_';
                    _ -> Node
                end, 
                {MatchingSubscrs, NotMatchingSubscrs} =
                lists:partition(fun(S) -> SubscriptionPred(NodeArg, S) end,
                                Subscriptions),
                case MatchingSubscrs of
                    [] -> error;
                    _ ->
                        UpdatedUser =
                        User#push_user{subscriptions = NotMatchingSubscrs},
                        mnesia:write(UpdatedUser),
                        ok
                end
        end
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> {error, ?ERR_ITEM_NOT_FOUND};
        {atomic, ok} -> {disabled, ok}
    end.

%-------------------------------------------------------------------------

%% Either device ID or a list of node IDs must be given. If none of these are in
%% the payload, the resource of the from jid will be interpreted as device ID.
%% If both device ID and node list are given, the device_id will be ignored and
%% only registrations matching a node ID in the given list will be removed.

unregister_client(#jid{lresource = <<"">>}, _, undefined, []) ->
    error;

unregister_client(#jid{luser = LUser, lserver = LServer, lresource = LResource},
                  RegisterHost, DeviceId, NodeIds) ->
    GetPubsubHost =
    fun(BackendId) ->
        MatchHead =
        #push_backend{id = BackendId, register_host = RegisterHost, pubsub_host = '$1'},
        case mnesia:select(push_backend, [{MatchHead, [], ['$1']}]) of
            [] -> error;
            [PubsubHost] -> PubsubHost
        end
    end,
    F = fun() ->
        case NodeIds of
            [] ->
                ChosenDeviceId = case DeviceId of
                    undefined -> LResource; 
                    <<"">> -> LResource;
                    _ -> DeviceId
                end,
                MatchingReg =
                mnesia:read({push_registration,
                             {{LUser, LServer}, ChosenDeviceId}}),
                case MatchingReg of
                    [] -> error;
                    [#push_registration{node = NodeId,
                                        backend_id = BackendId}] ->
                        case GetPubsubHost(BackendId) of
                            error -> error;

                            PubsubHost -> 
                                ?DEBUG("deleting registration of user ~p whith device_id "
                                       "~p",
                                       [jlib:jid_to_string({LUser, LServer, <<"">>}),
                                        NodeId]),
                                mod_pubsub:delete_node(PubsubHost, NodeId, PubsubHost),
                                mnesia:delete({push_registration,
                                               {{LUser, LServer}, ChosenDeviceId}}),
                                ok
                        end
                end;

            GivenNodes ->
                MatchHead = #push_registration{id = {{LUser, LServer}, '_'},
                                               node = '$1',
                                               backend_id = '$2',
                                               _='_'},
                Guard = {fun(N) -> lists:member(N, GivenNodes) end, '$1'},
                MatchingRegs =
                mnesia:select(push_registration, [{MatchHead, [Guard], ['$2']}]),
                case MatchingRegs of
                    [] -> error;
                    [BackendId] ->
                        case GetPubsubHost(BackendId) of
                            error -> error;

                            PubsubHost ->
                                lists:foldl(
                                    fun(#push_registration{id = Id, node = N}, Acc) ->
                                        mod_pubsub:delete_node(PubsubHost, N, PubsubHost),
                                        mnesia:delete({push_registration, Id}),
                                        [N|Acc]
                                    end,
                                    [],
                                    MatchingRegs)
                        end
                end
        end
    end,
    case mnesia:transcation(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, error} -> error;
        {atomic, Result} -> {unregistered, Result}
    end.
                
%-------------------------------------------------------------------------

list_registrations(#jid{luser = LUser, lserver = LServer}) ->
    F = fun() ->
        MatchHead = #push_registration{id = {{LUser, LServer}, '_'},
                                       device_name = '$1',
                                       node = '$2'},
        mnesia:select(push_registration, [{MatchHead, [], [{'$1', '$2'}]}])
    end,
    case mnesia:transaction(F) of
        {aborted, _} -> {error, ?ERR_INTERNAL_SERVER_ERROR};
        {atomic, RegList} -> {registrations, RegList}
    end.

%-------------------------------------------------------------------------

delete_registration({LUser, LServer} = BJid, Timestamp) ->
    F = fun() ->
        MatchHeadReg =
        #push_registration{id = {BJid, '$1'}, timestamp = Timestamp,
                           backend_id = '$2'},
        SelectedReg =
        mnesia:select(push_registration, [{MatchHeadReg, [], ['$1', '$2']}]),
        case SelectedReg of
            [] -> ok;
            [{DeviceId, BackendId}] ->
                MatchHeadBackend =
                #push_backend{id = BackendId, register_host = '$1'},
                SelectedBackend =
                mnesia:select(push_backend, [{MatchHeadBackend, [], ['$1']}]),
                case SelectedBackend of
                    [] -> ok;
                    [RegisterHost] ->
                        unregister_client({LUser, LServer, <<"">>},
                                          RegisterHost, DeviceId, [])
                end
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

combine_to_atom(Atom1, Atom2, Term) ->
    TermHash = erlang:phash2(Term),
    List =
    atom_to_list(Atom1) ++ "_" ++ atom_to_list(Atom2) ++ "_" ++
    integer_to_list(TermHash),
    list_to_atom(List).

%-------------------------------------------------------------------------

%% called on hook mgmt_queue_add_hook
on_store_stanza(From, #jid{luser = LUser, lserver = LServer, lresource = LResource}, Stanza) ->
    ?DEBUG("++++++++++++ Stored Stanza for ~p",
           [jlib:jid_to_string({LUser, LServer, LResource})]),
    PreferFullJid = fun(Subscriptions) ->
        MatchingFullJid =
        lists:filter(
            fun (S) when S#subscription.resource =:= LResource -> true;
                (_) -> false
            end,
            Subscriptions),
        case MatchingFullJid of
            [] -> Subscriptions;
            [S] -> S
        end
    end,
    F = fun() ->
        MatchHeadUser = #push_user{bare_jid = {LUser, LServer}, _='_'},
        case mnesia:select(push_user, [{MatchHeadUser, [], ['$_']}]) of
            [] -> ok;
            [#push_user{subscriptions = Subscriptions,
                        config = Config,
                        payload = StoredPayload} = User] ->
                PayloadRecord = make_payload_record(From, Stanza, StoredPayload),
                mnesia:write(User#push_user{payload = PayloadRecord}),
                Payload = make_payload(PayloadRecord, Config),
                ProcessSubscription =
                fun
                (#subscription{node = NodeId, reg_type = {local_reg, _}}) ->
                    MatchHeadReg =
                    #push_registration{id = {{LUser, LServer}, '_'},
                                       node = NodeId, _='_'},
                    SelectedRegs =
                    mnesia:select(push_registration, [{MatchHeadReg, [], ['$_']}]),
                    case SelectedRegs of
                        [] ->
                            ?DEBUG("No registration found for user ~p",
                                   [jlib:jid_to_string({LUser, LServer, LResource})]),
                            error;

                        [#push_registration{id = RegId,
                                            token = Token,
                                            app_id = AppId,
                                            backend_id = BackendId,
                                            silent_push = Silent,
                                            timestamp = Timestamp}] ->
                            dispatch_local(Payload, Token, AppId, BackendId,
                                           Silent, RegId, Timestamp, true)
                    end;
                        %Registrations ->
                        %    lists:foreach(
                        %        fun(#push_registration{bare_jid = BJid,
                        %                               token = Token,
                        %                               app_id = AppId,
                        %                               backend_id = BackendId,
                        %                               silent_push = Silent,
                        %                               timestamp = Timestamp}) ->
                        %            dispatch_local(Payload, Token, AppId,
                        %                           BackendId, Silent, BJid,
                        %                           Timestamp),
                        %        end,
                        %        Registrations);
                    
                (#subscription{node = NodeId,
                               reg_type = {remote_reg, PubsubHost, Secret}}) -> 
                    UserJid =
                    #jid{user = LUser, server = LServer, resource = <<"">>,
                         luser = LUser, lserver = LServer, lresource = LResource},
                    dispatch_remote(UserJid, PubsubHost, NodeId, Payload, Secret)
                end, 
                lists:foreach(ProcessSubscription, PreferFullJid(Subscriptions))
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

-spec(dispatch_local/8 ::
(
    Payload :: notification_payload(),
    Token :: binary(),
    AppId :: binary(),
    BackendId :: integer(),
    Silent :: boolean(),
    RegId :: {{binary(), binary()}, binary()},
    Timestamp :: erlang:timestamp(),
    AllowRelay :: boolean())
    -> ok
).

dispatch_local(Payload, Token, AppId, BackendId, Silent, RegId, Timestamp,
               AllowRelay) ->
   DisableArgs = {RegId, Timestamp},
    MatchHeadBackend = #push_backend{id = BackendId, worker = '$1',
                                     cluster_nodes = '$2', _='_'},
    [{Worker, ClusterNodes}] =
    mnesia:select(push_backend, [{MatchHeadBackend, [], ['$1', '$2']}]),
    case lists:member(node(), ClusterNodes) of
        true ->
            gen_server:cast(Worker,
                            {dispatch,
                             Payload, Token, AppId, Silent, DisableArgs});

        false ->
            case AllowRelay of
                false ->
                    ?DEBUG("Worker ~p is not running, cancel dispatching "
                           "push notification", [Worker]);
                true ->
                    Index = random:uniform(length(ClusterNodes)),
                    ChosenNode = lists:nth(Index, ClusterNodes),
                    ?DEBUG("Relaying push notification to node ~p",
                           [ChosenNode]),
                    gen_server:cast(
                        {Worker, ChosenNode},
                        {dispatch,
                         Payload, Token, AppId, Silent, DisableArgs})
            end
    end.
           
%-------------------------------------------------------------------------

-spec(dispatch_remote/5 ::
(
    User :: jid(),
    PubsubHost :: binary(),
    NodeId :: binary(),
    Payload :: notification_payload(),
    _Secret :: binary())
    -> ok
).

dispatch_remote(User, PubsubHostB, NodeId, Payload, _Secret) ->
    % TODO send secret as publish-option
    PubsubHost = jlib:string_to_jid(PubsubHostB),
    Fields =
    lists:foldl(
        fun
        ({Key, Value}, Acc) when is_binary(Value) ->
            [?VFIELD(atom_to_binary(Key, utf8), Value)|Acc];

        ({Key, Value}, Acc) when is_integer(Value) ->
            [?VFIELD(atom_to_binary(Key, utf8), integer_to_binary(Value))|Acc]
        end,
        [],
        Payload),
    Notification =
    #xmlel{name = <<"notification">>, attrs = [{<<"xmlns">>, ?NS_PUSH}],
           children =
           [#xmlel{name = <<"x">>, attrs = [{<<"xmlns">>, ?NS_XDATA}],
                   children = Fields}]},
    Iq =
    #iq{type = set, xmlns = ?NS_PUBSUB,
        sub_el =
        #xmlel{name = <<"publish">>, attrs = [{<<"node">>, NodeId}],
               children =
               [#xmlel{name = <<"item">>, children = [Notification]}]}},
    ejabberd_router:route(User, PubsubHost, Iq).

%-------------------------------------------------------------------------

on_resend_stanzas(#jid{luser = LUser, lserver = LServer}) ->
    ?DEBUG("+++++++++++ on_resend_stanzas", []),
    F = fun() ->
        case mnesia:read({push_user, {LUser, LServer}}) of
            [] -> ok;
            [User] ->
                mnesia:write(User#push_user{payload = #payload_record{}})
        end
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

% FIXME: test this!
% FIXME: when mod_pubsub has implemented publish-options another argument
%        'Options' is needed
incoming_notification(NodeId, #xmlel{name = <<"notification">>,
                                     attrs = [{<<"xmlns">>, ?NS_PUSH}],
                                     children = Children}) ->
    ProcessReg =
    fun(#push_registration{id = RegId,
                           token = Token,
                           secret = Secret,
                           app_id = AppId,
                           backend_id = BackendId,
                           silent_push = Silent,
                           timestamp = Timestamp}) ->
        % TODO: check secret (here or on node_push?)
        case get_xdata_elements(Children) of
           [] ->
               dispatch_local([], Token, AppId, BackendId, Silent, RegId,
                              Timestamp, false);

            XDataForms ->
                ParseResult =
                parse_form(
                    XDataForms, ?NS_PUSH_SUMMARY, [],
                    [{{single, <<"message-count">>},
                      fun erlang:binary_to_integer/1},
                     {single, <<"last-message-sender">>},
                     {single, <<"last-message-body">>},
                     {{single, <<"pending-subscription-count">>},
                      fun erlang:binary_to_integer/1},
                     {single, <<"last-subscription-sender">>}]),
                case ParseResult of
                    {result,
                     [MsgCount, MsgSender, MsgBody, SubscrCount,
                      SubscrSender]} ->
                        PayloadRecord =
                        #payload_record{
                            message_count = MsgCount,
                            last_message_sender = MsgSender,
                            last_message_body = MsgBody,
                            pending_subscription_count = SubscrCount,
                            last_subscription_sender = SubscrSender},
                        Payload = make_payload(PayloadRecord),
                        dispatch_local(Payload, Token, AppId, BackendId, Silent,
                                       RegId, Timestamp, false); 
                     _ -> ?INFO_MSG("Cancel dispatching push notification: "
                                    "item published on node ~p contains "
                                    "malformed data form", [NodeId])
                end
        end
    end,
    F = fun() ->
        MatchHeadReg = #push_registration{node = NodeId, _ = '_'},
        case mnesia:select(push_registration, [{MatchHeadReg, [], ['$_']}]) of
            [] ->
                %% this should never happen
                ?DEBUG("received push notification for non-existing registration "
                       "on node ~p", [NodeId]),
                error;

            Registrations ->
                lists:for_each(ProcessReg, Registrations)
        end
    end,
    mnesia:transaction(F);
           
incoming_notification(_NodeId, _Payload) ->
    error.    

%-------------------------------------------------------------------------

adjust_resume_timeout(Timeout, User) ->
    F = fun() ->
        case mnesia:read({push_client, jlib:jid_tolower(User)}) of
            [] -> Timeout;
            _ -> ?ADJUSTED_RESUME_TIMEOUT
        end
    end,
    case mnesia:transaction(F) of
        {atomic, AdjustedTimeout} -> AdjustedTimeout;
        _ ->
            ?DEBUG("+++++++ mod_push could not read timeout", [])
    end.

%-------------------------------------------------------------------------

start(Host, Opts) ->
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
    ?DEBUG("+++++++++++ Created mnesia tables", []),
    UserFields = record_info(fields, push_user),
    RegFields = record_info(fields, push_registration),
    case mnesia:table_info(push_user, attributes) of
        UserFields -> ok;
        _ -> mnesia:transform_table(push_user, ignore, UserFields)
    end,
    case mnesia:table_info(push_registration, attributes) of
        RegFields -> ok;
        _ -> mnesia:transform_table(push_registration, ignore, RegFields)
    end,
    % TODO: check if backends in registrations are still present
    % TODO: send push notifications (event server available) to all push users

    %%% FIXME: haven't thought about IQDisc parameter
    %%% FIXME: will only iqs by local users be handled?
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH, ?MODULE,
                                  process_iq, one_queue),
    ejabberd_hooks:add(mgmt_queue_add_hook, Host, ?MODULE, on_store_stanza,
                       50),
    ejabberd_hooks:add(mgmt_resend_stanzas_hook, Host, ?MODULE,
                       on_resend_stanzas, 50),
    ejabberd_hooks:add(mgmt_wait_for_resume_hook, Host, ?MODULE,
                       adjust_resume_timout, 50),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
                       on_disco_sm_features, 50),
    % FIXME: disco_sm_info is not implemented in mod_disco!
    %ejabberd_hooks:add(disco_sm_info, Host, ?MODULE, on_disco_sm_info, 50),
    F = fun() ->
        add_backends(Host, Opts),
        add_disco_hooks()
    end,
    case mnesia:transaction(F) of
        {atomic, _} -> ?DEBUG("++++++++ Added push backends", []);
        {aborted, Error} -> ?DEBUG("+++++++++ Error adding push backends: ~p", [Error])
    end.

%-------------------------------------------------------------------------

-spec(add_backends/2 ::
(
    Host :: binary(),
    Opts :: [any()])
    -> ok
).

add_backends(Host, Opts) ->
    CertFile = get_certfile(Opts),
    BackendOpts =
    gen_mod:get_module_opt(Host, ?MODULE, backends,
                           fun(O) when is_list(O) -> O end,
                           []),
    case parse_backends(BackendOpts, Host, CertFile, []) of
        invalid -> error;
        Parsed ->
            lists:foreach(
                fun({B, _}) ->
                    RegisterHost =B#push_backend.register_host,
                    PubsubHost = B#push_backend.pubsub_host,
                    ejabberd_hooks:add(adhoc_local_commands,
                                       RegisterHost,
                                       ?MODULE,
                                       process_adhoc_command,
                                       one_queue),
                    ?INFO_MSG("added adhoc command handler for app server ~p",
                              [RegisterHost]),
                    % FIXME: publish options not implemented yet:
                    %ejabberd_hooks:add(pubsub_publish_item_with_opts, BackendHost, ?MODULE,
                    %                   incoming_notification),
                    ejabberd_hooks:add(node_push_publish_item, PubsubHost, ?MODULE,
                                       incoming_notification, 50),
                    %% FIXME: haven't thought about IQDisc parameter
                    NewBackend =
                    case mnesia:read({push_backend, B#push_backend.id}) of
                        [] -> B;
                        [#push_backend{cluster_nodes = Nodes}] ->
                            NewNodes = lists:merge(Nodes, [node()]),
                            B#push_backend{cluster_nodes = NewNodes}
                    end,
                    ?DEBUG("######### writing to push_backend: ~p", [B]),
                    mnesia:write(NewBackend)
                end,
                Parsed),
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
                    [{B, A} || {B, A} <- Parsed, B#push_backend.type =:= Type],
                    start_workers(Host, Module, RemoveDupAuthData(MatchingType))
                end,
                [{apns, ?MODULE_APNS},
                 {gcm, ?MODULE_GCM},
                 {ubuntu, ?MODULE_UBUNTU},
                 {wns, ?MODULE_WNS}])
            % TODO:
            % subscribe to mnesia event {table, push_backend, detailed}, so workers can
            % be restarted when backend is updated
    end.

%-------------------------------------------------------------------------

-spec(add_disco_hooks/0 :: () -> ok). 

add_disco_hooks() ->
    BackendKeys = mnesia:all_keys(push_backend),
    lists:foreach(
        fun(K) ->
            [#push_backend{register_host = RegHost,
                          pubsub_host = PubsubHost}] =
            mnesia:read({push_backend, K}),
            mod_disco:register_feature(PubsubHost, ?NS_PUSH),
            ejabberd_router:register_route(RegHost),
            ejabberd_router:register_route(PubsubHost),
            ejabberd_hooks:add(disco_local_identity, PubsubHost, ?MODULE,
                               on_disco_pubsub_identity, 50),
            ejabberd_hooks:add(disco_local_identity, RegHost, ?MODULE,
                               on_disco_reg_identity, 50)
        end,
        BackendKeys).

%-------------------------------------------------------------------------

-spec start_workers(binary(), binary(), [{push_backend(), auth_data()}]) -> ok.

start_workers(_Host, _Module, []) -> ok;

start_workers(Host, Module,
              [{Backend,
               #auth_data{auth_key = AuthKey, certfile = CertFile}}|T]) ->
    Worker = Backend#push_backend.worker,
    BackendSpec =
    {Worker,
     {gen_server, start_link,
      [{local, Worker}, Module, [Host, AuthKey, CertFile], []]},
     permanent, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, BackendSpec),
    start_workers(Host, Module, T).

%-------------------------------------------------------------------------

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH),
    ejabberd_hooks:delete(mgmt_queue_add_hook, Host, ?MODULE,
                          on_store_stanza, 49),
    ejabberd_hooks:delete(mgmt_resend_stanzas_hook, Host, ?MODULE,
                          on_resend_stanzas, 50),
    %ejabberd_hooks:delete(mgmt_wait_for_resume_hook, Host, ?MODULE,
    %                      adjust_resume_timout, 50),
    F = fun() ->
        lists:foreach(fun(Id) ->
            [Backend] = mnesia:read({push_backend, Id}),
            RegisterHost = Backend#push_backend.register_host,
            PubsubHost = Backend#push_backend.pubsub_host,
            ejabberd_router:unregister_route(RegisterHost),
            ejabberd_router:unregister_route(PubsubHost),
            ejabberd_hooks:delete(disco_local_identity, RegisterHost, ?MODULE,
                                  on_disco_reg_identity, 50),
            ejabberd_hooks:delete(disco_local_identity, PubsubHost, ?MODULE,
                                  on_disco_pubsub_identity, 50),
            mod_disco:unregister_feature(PubsubHost, ?NS_PUSH)
        end,
        mnesia:all_keys(push_backend))
    end,
    mnesia:transaction(F).

%-------------------------------------------------------------------------

process_adhoc_command(Acc, From, #jid{lserver = LServer},
                      #adhoc_request{node = Command,
                                     action = <<execute>>,
                                     xdata = #xmlel{} = XData} = Request) ->
    Result = case Command of
        %<<"register-push-apns">> ->

        %<<"register-push-gcm">> ->

        <<"register-push-ubuntu">> ->
            Parsed = parse_form(XData,
                                undefined,
                                [{single, <<"token">>},
                                 {single, <<"application-id">>}],
                                [{single, <<"device-id">>},
                                 {single, <<"device-name">>}]),
            case Parsed of
                {result, [Token, AppId, DeviceId, DeviceName]} ->
                    register_client(From, LServer, ubuntu, Token,
                                    DeviceId, DeviceName, AppId, undefined);
                
                error -> error
            end;

        %<<"register-push-wns">> ->
            

        <<"unregister-push">> ->
            Parsed = parse_form(XData, undefined,
                                [], [{single, <<"device-id">>},
                                     {multi, <<"nodes">>}]),
            case Parsed of
                {result, [DeviceId, NodeIds]} -> 
                    unregister_client(From, LServer, DeviceId, NodeIds);

                _ -> error
            end;

        <<"push-registrations">> ->
            list_registrations(From);

        _ -> ok
    end,
    case Result of
        ok -> Acc;

        % TODO: include secret as publish-option
        {registered, {PubsubHost, Node, _Secret}} ->
            JidField = [?VFIELD(<<"jid">>, PubsubHost)],
            NodeField = case Node of
                <<"">> -> [];
                _ -> [?VFIELD(<<"node">>, Node)]
            end,
            Response =
            #adhoc_response{
                status = completed,
                elements = [#xmlel{name = <<"x">>,
                                   attrs = [{<<"xmlns">>, ?NS_XDATA},
                                            {<<"type">>, <<"result">>}],
                                   children = JidField ++ NodeField}]},
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
                fun({Name, Node}, ItemsAcc) ->
                    [?ITEM([?VFIELD(<<"device-name">>, Name),
                            ?VFIELD(<<"node">>, Node)])
                     |ItemsAcc]
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

process_iq(From, _To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    ?DEBUG("++++++++++++++++++ in process_iq", []),
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

                                {enabled, ResponseChildren} -> 
                                    NewSubEl =
                                    SubEl#xmlel{children = ResponseChildren},
                                    IQ#iq{type = result, sub_el = NewSubEl};

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
                            ?DEBUG("Received Invalid push iq from ~p",
                                   [jlib:jid_to_string(From)]),
                            IQ#iq{type = error,
                                  sub_el = [?ERR_NOT_ALLOWED, SubEl]}
                    end
            end
    end.
                    
%-------------------------------------------------------------------------

on_disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
    ?DEBUG("+++++++++ on_disco_sm_features", []),
    {result, [?NS_PUSH]};

on_disco_sm_features({result, Features}, _From, _To, <<"">>, _Lang) ->
    ?DEBUG("+++++++++ on_disco_sm_features", []),
    {result, [?NS_PUSH|Features]};

on_disco_sm_features(Acc, _From, _To, _, _Lang) ->
    ?DEBUG("+++++++++ on_disco_sm_features", []),
    Acc.

%%-------------------------------------------------------------------------

on_disco_pubsub_identity(Acc, _From, _To, <<"">>, _Lang) ->
    ?DEBUG("+++++++++ on_disco_pubsub_identity", []),
    PubsubIdentity =
    #xmlel{name = <<"identity">>,
           attrs = [{<<"category">>, <<"pubsub">>}, {<<"type">>, <<"push">>}],
           children = []},
    [PubsubIdentity|Acc];

on_disco_pubsub_identity(Acc, _From, _To, _, _Lang) ->
    ?DEBUG("+++++++++ on_disco_pubsub_identity", []),
    Acc.

%%-------------------------------------------------------------------------

on_disco_reg_identity(Acc, _From, To, <<"">>, _Lang) ->
    ?DEBUG("######## on_disco_reg_identity", []),
    RegHost = jlib:jid_to_string(To),
    F = fun() ->
        MatchHead =
        #push_backend{register_host = RegHost, app_name = '$1', _='_'},
        mnesia:select(push_backend, [{MatchHead, [], ['$1']}])
    end,
    case mnesia:transaction(F) of
        {atomic, AppNames} ->
            ?DEBUG("+++++++++ AppNames: ~p", [AppNames]),
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
            ?DEBUG("returning ~p", [Identities ++ Acc]),
            Identities ++ Acc;

        _ ->
            ?DEBUG("returning ~p", [Acc]),
            Acc
    end;

on_disco_reg_identity(Acc, _From, _To, _, _Lang) ->
    ?DEBUG("+++++++++ on_disco_reg_identity", []),
    ?DEBUG("returning ~p", [Acc]),
    Acc.
               
% FIXME: hook disco_sm_info is not implemented yet!
%on_disco_sm_info(Acc, From, To, Node, Lang) ->
%    % TODO:
%    % <x xmlns='jabber:x:data'>
%    %   <field var='FORM_TYPE'>
%    %     <value>http://jabber.org/protocol/pubsub#publish-options</value>
%    %   </field>
%    %   <field var='include-bodies'><value>0<value></field>
%    %   <field var='include-senders'><value>0<value></field>
%    %   <field var='include-message-count'><value>1<value></field>
%    % </x>
%    Acc.

%%-------------------------------------------------------------------------
