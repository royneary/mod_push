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

%% Note on function definition
%%   included is all defined plugin function
%%   it's possible not to define some function at all
%%   in that case, warning will be generated at compilation
%%   and function call will fail,
%%   then mod_pubsub will call function from node_hometree
%%   (this makes code cleaner, but execution a little bit longer)

%% API definition
-export([init/3, terminate/2,
	 options/0, features/0,
	 create_node_permission/6,
	 create_node/2,
	 delete_node/1,
	 purge_node/2,
	 subscribe_node/8,
	 unsubscribe_node/4,
	 publish_item/6,
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
	 get_items/6,
	 get_items/2,
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
    [{deliver_payloads, false},
     {notify_config, false},
     {notify_delete, false},
     {notify_retract, false},
     {purge_offline, false},
     {persist_items, false},
     {max_items, ?MAXITEMS},
     {subscribe, false},
     {access_model, whitelist},
     {roster_groups_allowed, []},
     {publish_model, publishers},
     {notification_type, headline},
     {max_payload_size, ?MAX_PAYLOAD_SIZE},
     {send_last_published_item, never},
     {deliver_notifications, false},
     {presence_based_delivery, false}].

% TODO: add publish-only-affiliation when implemented
features() ->
    ?DEBUG("+++++++ In node_push:features", []),
    [%"create-nodes",
     %"delete-nodes",
     <<"delete-items">>,
     %"instant-nodes",
     %"outcast-affiliation",
     %"persistent-items",
     <<"publish">>
     %"purge-nodes",
     %"retract-items",
     %"retrieve-affiliations",
     %"retrieve-items",
     %"retrieve-subscriptions",
     %"subscribe",
     %"subscription-notifications"
    ].

create_node_permission(_Host, _ServerHost, _Node, _ParentNode, _Owner, _Access) ->
    {result, true}.

create_node(NodeIdx, Owner) ->
    node_hometree:create_node(NodeIdx, Owner),
    {result, NodeIdx}.
        
delete_node(Removed) ->
    node_hometree:delete_node(Removed).

subscribe_node(NodeId, Sender, Subscriber, AccessModel, SendLast, PresenceSubscription, RosterGroup, Options) ->
    node_hometree:subscribe_node(NodeId, Sender, Subscriber, AccessModel, SendLast, PresenceSubscription, RosterGroup, Options).

unsubscribe_node(NodeId, Sender, Subscriber, SubID) ->
    node_hometree:unsubscribe_node(NodeId, Sender, Subscriber, SubID).

publish_item(NodeIdx, Publisher, Model, MaxItems, ItemId, Payload) ->
    %% TODO: don't really publish item, only call hook?
    case node_hometree:publish_item(NodeIdx, Publisher, Model, MaxItems, ItemId, Payload) of
        {result, {default, broadcast, _}} ->
            #pubsub_node{nodeid = {Host, NodeId}} =
            nodetree_tree:get_node(NodeIdx),
            Authenticated =
            ejabberd_hooks:run_fold(node_push_publish_item, Host,
                                    false, [Host, NodeId, Payload]),
            case Authenticated of
                true -> {result, ok};
                false -> {error, ?ERR_NOT_AUTHORIZED}
            end;

        Error -> Error
    end. 

remove_extra_items(NodeId, MaxItems, ItemIds) ->
    node_hometree:remove_extra_items(NodeId, MaxItems, ItemIds).

delete_item(NodeId, Publisher, PublishModel, ItemId) ->
    node_hometree:delete_item(NodeId, Publisher, PublishModel, ItemId).

purge_node(NodeId, Owner) ->
    node_hometree:purge_node(NodeId, Owner).

get_entity_affiliations(Host, Owner) ->
    node_hometree:get_entity_affiliations(Host, Owner).

get_node_affiliations(NodeId) ->
    node_hometree:get_node_affiliations(NodeId).

get_affiliation(NodeId, Owner) ->
    node_hometree:get_affiliation(NodeId, Owner).

set_affiliation(NodeId, Owner, Affiliation) ->
    node_hometree:set_affiliation(NodeId, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    node_hometree:get_entity_subscriptions(Host, Owner).

get_node_subscriptions(NodeId) ->
    node_hometree:get_node_subscriptions(NodeId).

get_subscriptions(NodeId, Owner) ->
    node_hometree:get_subscriptions(NodeId, Owner).

set_subscriptions(NodeId, Owner, Subscription, SubId) ->
    node_hometree:set_subscriptions(NodeId, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_hometree:get_pending_nodes(Host, Owner).

get_states(NodeId) ->
    node_hometree:get_states(NodeId).

get_state(NodeId, JID) ->
    node_hometree:get_state(NodeId, JID).

set_state(State) ->
    node_hometree:set_state(State).

get_items(NodeId, From) ->
    node_hometree:get_items(NodeId, From).

get_items(NodeId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_hometree:get_items(NodeId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId).
    
get_item(NodeId, ItemId) ->
    node_hometree:get_item(NodeId, ItemId).

get_item(NodeId, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_hometree:get_item(NodeId, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId).
    
set_item(Item) ->
    node_hometree:set_item(Item).

get_item_name(Host, Node, Id) ->
    node_hometree:get_item_name(Host, Node, Id).

node_to_path(Node) -> node_hometree:node_to_path(Node).

path_to_node(Path) -> node_hometree:path_to_node(Path).
