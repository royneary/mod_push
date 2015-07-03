%%==============================================================================
%% Copyright 2010 Erlang Solutions Ltd.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%==============================================================================

-module(mod_push_SUITE).
-compile(export_all).

-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("exml/include/exml_stream.hrl"). 

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, tests}].

groups() ->
    [{tests, [sequence], [register_story,
                  disco_stream_story,
                  disco_appserver_story,
                  disco_pubsub_story,
                  enable_story,
                  disable_story,
                  unregister_story
                 ]}].

suite() ->
    escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

ets_owner() ->
    receive
        stop -> exit(normal);
        _ -> ets_owner()
    end.

init_per_suite(Config) ->
    Pid = spawn(fun ets_owner/0),
    TabId =
    ets:new(mod_push_registrations, [bag, public, {heir, Pid, []}]),
    escalus:init_per_suite(Config),
    [{table, TabId}, {table_owner, Pid} | Config].

end_per_suite(Config) ->
    ?config(table_owner, Config) ! stop,
    escalus:end_per_suite(Config).

init_per_group(_GroupName, Config) ->
    escalus:create_users(Config).

end_per_group(_GroupName, Config) ->
    escalus:delete_users(Config).

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

%%--------------------------------------------------------------------
%% stories
%%--------------------------------------------------------------------

register_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->
        AppServer = get_option(escalus_server, Config),
        DeviceName = get_option(device_name, Config, alice),

        %% list registrations before registering
        ListRegistrationsRequest =
        adhoc_request(<<"list-push-registrations">>, AppServer, []),
        escalus:send(Alice, ListRegistrationsRequest),
        ListReply1 = escalus:wait_for_stanza(Alice),
        escalus:assert(is_adhoc_response,
                       [<<"list-push-registrations">>, <<"completed">>],
                       ListReply1),
        escalus:assert(fun adhoc_without_form/1, ListReply1), 

        %% register with valid payload
        ApnsPayloadOk =
        [{<<"token">>, get_option(apns_token, Config, alice)},
         {<<"device-name">>, get_option(device_name, Config, alice)}],

        UbuntuPayloadOk =
        [{<<"token">>, get_option(ubuntu_token, Config, alice)},
         {<<"application-id">>, get_option(application_id, Config, alice)},
         {<<"device-name">>, get_option(device_name, Config, alice)}],

        TestPayloadOk =
        fun({Node, Payload}) ->
            Request = adhoc_request(Node, AppServer, Payload),
            escalus:send(Alice, Request),
            Reply = escalus:wait_for_stanza(Alice),
            escalus:assert(is_adhoc_response, [Node, <<"completed">>],
                           Reply),
            XData = get_adhoc_payload(Reply),
            escalus:assert(fun valid_response_form/1, XData),
            XDataValueOk = fun(Key, XDataForm) ->
                is_valid_xdata_value(get_xdata_value(Key, XDataForm))
            end,
            escalus:assert(XDataValueOk, [<<"jid">>], XData),
            escalus:assert(XDataValueOk, [<<"node">>], XData),
            escalus:assert(XDataValueOk, [<<"secret">>], XData),
            ets:insert(?config(table, Config),
                       {alice,
                        get_xdata_value(<<"jid">>, XData),
                        get_xdata_value(<<"node">>, XData),
                        get_xdata_value(<<"secret">>, XData),
                        DeviceName})
        end,
        lists:foreach(
            TestPayloadOk,
            filtermap_by_backend(
                [{apns, {<<"register-push-apns">>, ApnsPayloadOk}},
                 {ubuntu, {<<"register-push-ubuntu">>, UbuntuPayloadOk}}],
                Config
            )
        ),

        %% list registrations after registering
        escalus:send(Alice, ListRegistrationsRequest),
        ListReply2 = escalus:wait_for_stanza(Alice),
        escalus:assert(is_adhoc_response,
                       [<<"list-push-registrations">>, <<"completed">>],
                       ListReply2),
        Regs = ets:select(?config(table, Config),
                          [{{alice, '$1', '$2', '$3', '$4'}, [], [{{'$2', '$4'}}]}]),
        XData = get_adhoc_payload(ListReply2),
        escalus:assert(fun valid_response_form/1, XData),
        escalus:assert(fun has_registrations/2, [Regs], XData)

    end).

disco_stream_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->
        
        Request = escalus_stanza:disco_info(escalus_utils:get_short_jid(Alice)),
        escalus:send(Alice, Request),
        escalus:assert(has_feature, [<<"urn:xmpp:push:0">>],
                       escalus:wait_for_stanza(Alice))
        
    end).

disco_appserver_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->

        AppServer = get_option(escalus_server, Config),
        AppName = get_option(app_name, Config, alice),
        Request = escalus_stanza:disco_info(AppServer),
        escalus:send(Alice, Request),
        Reply = escalus:wait_for_stanza(Alice),
        escalus:assert(has_identity, [<<"app-server">>, AppName], Reply)

    end).

disco_pubsub_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->

        {alice, PubsubServer, _, _, _} = hd(ets:lookup(?config(table, Config), alice)),
        Request = escalus_stanza:disco_info(PubsubServer),
        escalus:send(Alice, Request),
        Reply = escalus:wait_for_stanza(Alice),
        escalus:assert(has_feature, [<<"urn:xmpp:push:0">>], Reply),
        escalus:assert(has_identity, [<<"pubsub">>, <<"push">>], Reply)

    end).


enable_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->

        ok

    end).

disable_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->

        ok

    end).

unregister_story(Config) ->
    escalus:story(Config, [{alice, 1}], fun(Alice) ->

        AppServer = get_option(escalus_server, Config),

        UnregRequestOk =
        adhoc_request(<<"unregister-push">>, AppServer, []),
        escalus:send(Alice, UnregRequestOk),
        Reply = escalus:wait_for_stanza(Alice),
        escalus:assert(is_adhoc_response, [<<"unregister-push">>, <<"completed">>],
                       Reply),
        escalus:assert(fun adhoc_without_form/1, Reply),
        ets:delete(?config(table, Config), alice)

    end).

%%--------------------------------------------------------------------
%% helpers
%%--------------------------------------------------------------------

get_option(Key, Config) ->
    escalus_config:get_config(Key, Config).

get_option(Key, Config, User) ->
    GenericOption = list_to_atom("escalus_" ++ atom_to_list(Key)),
    UserSpec = escalus_users:get_userspec(Config, User),
    escalus_config:get_config(Key, UserSpec, GenericOption, Config, undefined).

adhoc_request(Node, Host, Payload) ->
    Form = case Payload of
        [] -> [];
        _ -> 
            escalus_stanza:x_data_form(<<"submit">>,
                                       escalus_stanza:search_fields(Payload))
    end,
    Request = escalus_stanza:adhoc_request(Node, Form), 
    escalus_stanza:to(Request, Host).

filtermap_by_backend(List, Config) ->
    filtermap_by_backend(List, Config, []).

filtermap_by_backend([], _, Acc) -> Acc;
filtermap_by_backend([{Backend, Entry}|T], Config, Acc) ->
    case lists:member(Backend, get_option(push_backends, Config)) of
        true -> filtermap_by_backend(T, Config, [Entry|Acc]);
        false -> filtermap_by_backend(T, Config, Acc)
    end.

get_adhoc_payload(Stanza) ->
    exml_query:path(Stanza, [{element, <<"command">>}, {element, <<"x">>}]).

valid_response_form(#xmlel{name = <<"x">>} = Element) ->
    Ns = exml_query:attr(Element, <<"xmlns">>),
    Type = exml_query:attr(Element, <<"type">>),
    (Ns =:= <<"jabber:x:data">>) and (Type =:= <<"result">>).

has_registrations(Regs, Element) ->
    Items =
    exml_query:paths(Element, [{element, <<"item">>}]),
    ItemFields =
    lists:map(
        fun(Item) -> [exml_query:paths(Item, [{element, <<"field">>}])] end, Items),
    GetValues =
    fun
    F([El|T], {NodeAcc, DeviceNameAcc}) ->
        case exml_query:attr(El, <<"var">>) of
            <<"node">> ->
                Node = exml_query:path(El, [{element, <<"value">>}, cdata]),
                F(T, {Node, DeviceNameAcc});
            <<"device-name">> ->
                DeviceName = exml_query:path(El, [{element, <<"value">>}, cdata]),
                F(T, {NodeAcc, DeviceName});
            _ -> F(T, {NodeAcc, DeviceNameAcc})
        end;
    F([], Result) -> Result
    end,
    Values =
    lists:foldl(
        fun(Fs, Acc) ->
            [lists:foldl(GetValues, {undefined, undefined}, Fs) | Acc]
        end,
        [],
        ItemFields),
    io:format("Regs = ~p, Values = ~p", [Regs, Values]),
    (length(Regs) =:= length(Values)) and (Regs -- Values =:= []).

adhoc_without_form(Stanza) ->
    get_adhoc_payload(Stanza) =:= undefined.

is_valid_xdata_value(Value) ->
    is_binary(Value) and (Value =/= <<"">>).

get_xdata_value(Key, XData) ->
    Fields = exml_query:paths(XData, [{element, <<"field">>}]),
    FindValue =
    fun
    F([Field|T]) ->
        case exml_query:attr(Field, <<"var">>) of
            Key -> exml_query:path(Field, [{element, <<"value">>}, cdata]);
            _ -> F(T)
        end;
    F([]) -> undefined
    end,
    FindValue(Fields).

