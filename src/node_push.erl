%%%----------------------------------------------------------------------
%%% File    : node_push.erl
%%% Author  : Christian Ulrich <christian@rechenwerk.net>
%%% Purpose : mod_push's pubsub plugin
%%%           
%%% Created : 24 Mar 2015 by Christian Ulrich <christian@rechenwerk.net>
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

-module(node_push).
-author('christian@rechenwerk.net').

-include("pubsub.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-behaviour(gen_pubsub_node).

%% API definition
-export([init/3, terminate/2,
	 options/0, features/0,
	 create_node_permission/6,
	 create_node/2,
	 delete_node/1,
	 purge_node/2,
	 subscribe_node/8,
	 unsubscribe_node/4,
	 publish_item/7,
	 delete_item/4,
	 remove_extra_items/3,
	 get_entity_affiliations/2,
	 get_node_affiliations/1,
	 get_affiliation/2,
	 set_affiliation/3,
	 get_entity_subscriptions/2,
	 get_node_subscriptions/1,
	 get_subscriptions/2,
	 set_subscriptions/4,
	 get_pending_nodes/2,
	 get_states/1,
	 get_state/2,
	 set_state/1,
	 get_items/3,
	 get_items/7,
	 get_item/7,
	 get_item/2,
	 set_item/1,
	 get_item_name/3,
     node_to_path/1,
     path_to_node/1
	]).


init(Host, ServerHost, Opts) ->
    node_hometree:init(Host, ServerHost, Opts).

terminate(Host, ServerHost) ->
    node_hometree:terminate(Host, ServerHost).

options() ->
    [{deliver_payloads, true},
     {notify_config, false},
     {notify_delete, false},
     {notify_retract, true},
     {purge_offline, false},
     {persist_items, true},
     {max_items, 1},
     {subscribe, true},
     {access_model, whitelist},
     {roster_groups_allowed, []},
     {publish_model, publishers},
     {notification_type, headline},
     {max_payload_size, ?MAX_PAYLOAD_SIZE},
     {send_last_published_item, never},
     {deliver_notifications, true},
     {presence_based_delivery, false},
     {secret, [<<"">>]}].

features() ->
    [<<"create-nodes">>,
     <<"delete-nodes">>,
     <<"delete-items">>,
     <<"instant-nodes">>,
     <<"modify-affiliations">>,
     <<"multi-subscribe">>,
     <<"persistent-items">>,
     <<"publish">>,
     <<"publish-only-affiliation">>,
     <<"purge-nodes">>,
     <<"retrieve-affiliations">>,
     <<"retrieve-items">>,
     <<"retrieve-subscriptions">>,
     <<"subscribe">>,
     <<"subscription-options">>].

create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access) ->
    node_flat:create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access).

create_node(Nidx, Owner) ->
    node_hometree:create_node(Nidx, Owner).
        
delete_node(Removed) ->
    node_hometree:delete_node(Removed).

subscribe_node(Nidx, Sender, Subscriber, AccessModel, SendLast, PresenceSubscription, RosterGroup, Options) ->
    node_flat:subscribe_node(Nidx, Sender, Subscriber, AccessModel, SendLast,
                             PresenceSubscription, RosterGroup, Options).

unsubscribe_node(Nidx, Sender, Subscriber, SubID) ->
    node_hometree:unsubscribe_node(Nidx, Sender, Subscriber, SubID).

publish_item(Nidx, Publisher, Model, MaxItems, ItemId, Payload, PubOpts) ->
    %% mod_push's internal app server must use nodetree_virtual and receives
    %% the published items from the node_push_publish_item hook, an XEP-0114-
    %% connected app server must use nodetree_tree and receives the items via
    %% XEP-0060 notification stanzas
    ?DEBUG("++++++ node_push:publish_item, node = ~p", [Nidx]),
    case is_binary(Nidx) of
        true ->
            VirtualNode = nodetree_virtual:get_node(Nidx),
            [{<<"">>, Host, <<"">>}] = VirtualNode#pubsub_node.owners,
            NodeId = VirtualNode#pubsub_node.nodeid,
            Result =
            ejabberd_hooks:run_fold(node_push_publish_item, Host,
                                    internal_server_error,
                                    [NodeId, Payload, PubOpts]),
            ?DEBUG("+++++ node_push_publish_item hook result: ~p", [Result]),
            case Result of
                ok -> {result, default};
                bad_request -> {error, ?ERR_BAD_REQUEST};
                node_not_found -> {error, ?ERR_ITEM_NOT_FOUND};
                not_authorized -> {error, ?ERR_FORBIDDEN};
                internal_server_error -> {error, ?ERR_INTERNAL_SERVER_ERROR}
            end;

        false ->
            #pubsub_node{options = Options} = nodetree_tree:get_node(Nidx),
            ?DEBUG("+++++ Node options = ~p", [Options]),
            Secret = proplists:get_value(secret, Options, <<"">>),
            case mod_push:check_secret(Secret, PubOpts) of
                true ->
                    ?DEBUG("+++++ right secret!", []),
                    Result =
                    node_hometree:publish_item(Nidx, Publisher, Model, MaxItems,
                                               ItemId, Payload, PubOpts),
                    ?DEBUG("+++++ node_hometree:publish_item returned ~p",
                           [Result]),
                    Result;
                false ->
                    ?DEBUG("++++++ wrong secret, should be ~p", [Secret]),
                    {error, ?ERR_FORBIDDEN}
            end
    end.
    
remove_extra_items(Nidx, MaxItems, ItemIds) ->
    node_hometree:remove_extra_items(Nidx, MaxItems, ItemIds).

delete_item(Nidx, Publisher, PublishModel, ItemId) ->
    node_hometree:delete_item(Nidx, Publisher, PublishModel, ItemId).

purge_node(Nidx, Owner) ->
    node_hometree:purge_node(Nidx, Owner).

get_entity_affiliations(Host, Owner) ->
    node_hometree:get_entity_affiliations(Host, Owner).

get_node_affiliations(Nidx) ->
    node_hometree:get_node_affiliations(Nidx).

get_affiliation(Nidx, Owner) ->
    node_hometree:get_affiliation(Nidx, Owner).

set_affiliation(Nidx, Owner, Affiliation) ->
    node_hometree:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    node_hometree:get_entity_subscriptions(Host, Owner).

get_node_subscriptions(Nidx) ->
    node_hometree:get_node_subscriptions(Nidx).

get_subscriptions(Nidx, Owner) ->
    node_hometree:get_subscriptions(Nidx, Owner).

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    node_hometree:set_subscriptions(Nidx, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_hometree:get_pending_nodes(Host, Owner).

get_states(Nidx) ->
    node_hometree:get_states(Nidx).

get_state(Nidx, JID) ->
    node_hometree:get_state(Nidx, JID).

set_state(State) ->
    node_hometree:set_state(State).

get_items(Nidx, From, RSM) ->
    node_hometree:get_items(Nidx, From, RSM).

get_items(Nidx, JID, AccessModel, PresenceSubscription, RosterGroup, SubId, RSM) ->
    node_hometree:get_items(Nidx, JID, AccessModel,
	PresenceSubscription, RosterGroup, SubId, RSM).

get_item(Nidx, ItemId) ->
    node_hometree:get_item(Nidx, ItemId).

get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_hometree:get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription,
                           RosterGroup, SubId).
    
set_item(Item) ->
    node_hometree:set_item(Item).

get_item_name(Host, Node, Id) ->
    node_hometree:get_item_name(Host, Node, Id).

node_to_path(Node) -> node_flat:node_to_path(Node).

path_to_node(Path) -> node_flat:path_to_node(Path).
