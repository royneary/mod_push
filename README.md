# mod_push

Note: This project is not maintained anymore. Mainline ejabberd now [ships](https://github.com/processone/ejabberd/pull/1881) the app server part of XEP-0357.

mod_push implements [XEP-0357 (Push)](http://www.xmpp.org/extensions/xep-0357.html)
for ejabberd and includes a messaging-focussed app server for the common push
notification services. These are
* [APNS (Apple push notification service)](https://developer.apple.com/library/ios/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/ApplePushService.html)
* [GCM (Google cloud messaging)](https://developers.google.com/cloud-messaging)
* [Mozilla SimplePush](https://wiki.mozilla.org/WebAPI/SimplePush)
* [Ubuntu Push](https://developer.ubuntu.com/en/start/platform/guides/push-notifications-client-guide)
* [WNS (Windows notification service)](https://msdn.microsoft.com/en-us//library/windows/apps/hh913756.aspx)

mod_push is a project in the Google Summer of Code 2015 and is still pre-alpha. Please send feedback.

## Prerequisites
* Erlang/OTP 17 or higher
* If app server backends are used a working starttls configuration is required; by default the certificate set by the 'certfile' option will be used for communication with the push providers
* for using APNS [this OTP fix](https://github.com/processone/otp/commit/45aaefe739c8ea6c33d140d056b94fcf53c3df30) is needed (see [this blog post](https://blog.process-one.net/apple-increasing-security-of-push-service-ahead-of-wwdc))
* for now an [ejabberd branch](https://github.com/royneary/ejabberd/tree/mod_push_adjustments) with mod_push-specific modifications is needed

## Installation
```bash
git clone https://github.com/royneary/mod_push.git
# copy the source code folder to the module sources folder of your ejabberd
# installation (may be different on your machine)
sudo cp -R mod_push /var/spool/jabber/.ejabberd-modules/sources/
# if done right ejabberdctl will list mod_push as available module
ejabberdctl modules_available
# automatically compile and install mod_push
ejabberdctl module_install mod_push 
```

## Important implementation details
mod_push depends on stream management (XEP-0198) stream resumption. A client will only receive push notifications when the server detects a dead TCP connection. After that the server will wait for the client to resume the stream. We call this state "pending" state (a.k.a. zombie state). To enter the pending state clients are expected to close their TCP connection without sending `</stream>`. They will typically do so in a handler the mobile OS will call before moving the application into background.

Administrators sometimes have to restart XMPP servers. Ejabberd will close all open streams in that event which means that after a restart stream management will no longer notify mod_push about incoming stanzas for the previous push clients. As a solution to this problem mod_push will send a push notification to all previously pending push users after a restart so they can open a new connection. Currently this notification can not be distinguished from a "normal" notification (e.g. one sent in the event of an incoming message). This means a client will typically try to resume the stream which will fail as it does not exist anymore. Then it can start a new stream and re-enable push.
Registrations at mod_push's app server will not be affected by server restarts so clients do not need to re-register. 

## Configuration
### stream management
The option `resume_timeout` for module ejabberd_c2s in the listen-section of
ejabberd.yml must be set to a value greater than 0 (default value is 300). This enables
stream resumption but the value has no effect on push users since mod_push
overwrites this value to keep them pending for a long time.

### pubsub configuration
An XEP-0357 app server requires a pubsub service where XMPP servers can publish
notifications. The pubsub service needs a dedicated hostname.
If the internal app server shall be used, that is mod_push's option `backends` is not an empty list `[]`, mod_pubsub must be configured to fulfill the requirements of XEP-0357. The `push` plugin delivered by mod_push takes care of that. For the internal app server `nodetree: "virtual"` must be set. The `push` plugin can also be used to provide a pubsub service for external app server, such as [Oshiya](https://github.com/royneary/oshiya). In that case `nodetree = "tree"` must be set.
```yaml
mod_pubsub:
  host : "push.example.net"
  nodetree : "virtual"
  plugins: 
    - "push"
```
Note: switching from `nodetree = "tree"` to `nodetree = "virtual"` currently causes mod_pubsub crashes. A workaround is to clear the pubsub mnesia tables. This affects all pubsub services on the ejabberd instance.
```bash
ejabberdctl debug
mnesia:clear_table(pubsub_node).
mnesia:clear_table(pubsub_state).
mnesia:clear_table(pubsub_index).
mnesia:clear_table(pubsub_subscription).
mnesia:clear_table(pubsub_item).
```

If you want to allow other XMPP servers to use your app server you need a SRV record in your DNS server:
```fundamental
_xmpp-server._tcp.push.example.net. 86400 IN SRV 5 0 5269 example.net.
```

### XEP-0357 configuration
#### User-definable options
There are user-definable config options to specify what contents should be in
a push notification. You can set default values for them in the mod_push
section:
* `include_senders`: include the jids of the last message sender and the last subscription sender (default: false)
* `include_message_count`: include the number of queued messages (default: true)
* `include_subscription_count`: include the number of queued subscription requests (default: true)
* `include_message_bodies`: include the message contents (default: false)

example:
```yaml
mod_push:
  include_senders: true
  include_message_count: true
  include_subscription_count: true
```
A user can obtain the current push configuration (the server's default configuration if he never changed it) by sending a service discovery info request to his bare jid. The response will contain a form of `FORM_TYPE` `urn:xmpp:push:options`.

```xml
<iq from='bill@example.net' to='bill@example.net/Home' id='x13' type='result'>
  <query xmlns='http://jabber.org/protocol/disco#info'>
    <x xmlns='jabber:x:data' type='result'>
      <field type='hidden' var='FORM_TYPE'><value>urn:xmpp:push:options</value></field>
      <field type='boolean' var='include-senders'><value>0</value></field>
      <field type='boolean' var='include-message-count'><value>1</value></field>
      <field type='boolean' var='include-subscription-count'><value>1</value></field>
      <field type='boolean' var='include-message-bodies'><value>0</value></field>
    </x>
    <identity category='account' type='registered'/>
    <feature var='http://jabber.org/protocol/disco#info'/>
    <feature var='urn:xmpp:push:0'/>
  </query>
</iq>
```

A can change her configuration by including a form of `FORM_TYPE` `urn:xmpp:push:options` into the enable request. Note that this configuration is a per-user configuration that is valid for all resources. To send publish-options which are passed to the pubsub-service when publishing a notification an other form of `FORM_TYPE` `http://jabber.org/protocol/pubsub#publish-options` can be included. In this example it contains a secret a pubsub service might require as credential. mod_push's internal app server does require providing the secret obtained during registration.

```xml
<iq type='set' to='example.net' id='x42'>                                                
  <enable xmlns='urn:xmpp:push:0' jid='push.example.net' node='v9S+H8VTFgEl'>
    <x xmlns='jabber:x:data' type='submit'>
      <field var='FORM_TYPE'><value>urn:xmpp:push:options</value></field>
      <field var='include-senders'><value>0</value></field>
      <field var='include-message-count'><value>1</value></field>
      <field var='include-message-bodies'><value>0</value></field>
      <field var='include-subscription-count'><value>1</value></field>
    </x>
    <x xmlns='jabber:x:data' type='submit'>
      <field var='FORM_TYPE'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>
      <field var='secret'><value>szLo+l17Q0ZQr2dShnyQiYn/stqicShK</value></field>
    </x>
  </enable>                      
</iq>
```

mod_push provides in-band configuration although not recommended by XEP-0357. In order to prevent privilege escalation as mentioned in the XEP subsequent enable requests are only allowed to disable options, not enable them. A fresh configuration is only possible after all push-enabled resources have been disabled.

The response to an enable request with configuration form will include
those values that have been accepted for the new configuration.

#### restrict access
The option `access_backends` allows restricting access to the app server backends using ejabberd's acl feature. `access_backends` may be defined in the mod_push section. The default value is `all`. The example configuration only allows local XMPP users to use the app server.

### App server configuration
You can set up multiple app server backends for the different push
notification services. This is not required, your users can use external app
servers too.

#### Default options
* `certfile`: the path to a certificate file (pem format, containing both certificate and private key) used as default for all backends

#### Common options
* `register_host`: the app server host where users can register. Must be a subdomain of the XMPP server hostname or the XMPP server hostname itself. The advantage of choosing the XMPP server hostname is that clients don't have to guess any subdomain (XEP-0357 does not define service discovery for finding app servers).
* `pubsub_host`: the pubsub_host of the backend
* `type`: apns|gcm|mozilla|ubuntu|wns
* `app_name`: the name of the app the backend is configured for, will be send to the user when service discovery is done on the register_host; the default value is "any", but that's only a valid value for backend types that don't require developer credentials, that is ubuntu and mozilla
* `certfile`: the path to a certificate file (pem format, containing both certificate and private key) the backend will use for TLS

#### APNS-specific options
* `certfile`: path to a pem file containing the developer's private key and the certificate obtained from Apple during the provisioning procedure

#### GCM-specific options
* `auth_key`: the API key obtained from Google's api console

#### WNS
* `auth_key`: the client secret obtained from Microsoft Developer Center
* `package_sid`: the package SID obtained from Microsoft Developer Center

### Example configuration
```yaml
access:
  local_users:
    local: allow

acl:
  local:
    server: "example.net"

modules:
  mod_pubsub:
    host : "push.example.net"
    nodetree : "virtual"
    plugins: 
      - "push"
  
  mod_push:
    include_senders: true
    access_backends: local_users
    certfile: "/etc/ssl/private/example.pem"
    backends:
      -
        type: ubuntu
        register_host: "example.net"
        pubsub_host: "push.example.net"
      -
        type: gcm
        app_name: "chatninja"
        register_host: "example.net"
        pubsub_host: "push.example.net"
        auth_key: "HgeGfbhwplu7F-fjCUf6gBfkauUaq12h0nHazqc" 
      -
        type: apns
        app_name: "chatninja"
        register_host: "example.net"
        pubsub_host: "push.example.net"
        certfile: "/etc/ssl/private/apns_example_app.pem"  
```

## App server usage
Clients can communicate with the app server by sending adhoc requests containing an XEP-0004 data form:
These are the available adhoc commands:
* `register-push-apns`: register at an APNS backend
* `register-push-gcm`: register at a GCM backend
* `register-push-mozilla`: register at a Mozilla SimplePush backend
* `register-push-ubuntu`: register at an Ubuntu Push backend
* `register-push-wns`: register at a WNS backend
* `list-push-registrations`: request a list of all registrations of the requesting user
* `unregister-push`: delete the user's registrations (all of them or those matching a given list of node names)

Example:
```xml
<iq type='set' to='example.net' id='exec1'>
  <command xmlns='http://jabber.org/protocol/commands'
           node='register-push-apns'
           action='execute'>
    <x xmlns='jabber:x:data' type='submit'>
      <field
      var='token'>
        <value>r3qpHKmzZHjYKYbG7yI4fhY+DWKqFZE5ZJEM8P+lDDo=</value>
      </field>
      <field var='device-name'><value>Home</value></field>
    </x>
  </command>
</iq>
```
There are common fields which a client has to include for every backend type and there are backend-specific fields.

### Common fields for the register commands
* `token`: the device identifier the client obtained from the push service
* `device-id`: a device identifier a client can define explicitly (the jid's resource part will be used otherwise)
* `device-name`: an optional name that will be included in the response to the list-push-registrations command

### register-push-apns fields
* `token`: the base64-encoded binary token obtained from APNS

### register-push-ubuntu fields
* `application-id`: the app id as registered at Ubuntu's push service

### register-push-wns fields
* `token`: the channel URI which must be escaped according to RFC 2396, you can use .NET's Uri.EscapeUriString method for that

### unregister-push fields
* `device-id`: Either device ID or a list of node IDs must be given. If none of these are in the payload, the resource of the from jid will be interpreted as device ID. If both device ID and node list are given, the device ID will be ignored and only registrations matching a node ID in the given list will be removed.
* `nodes`: a list of node names; registrations mathing one of them will be removed

### register command response
The app server returns the jid of the pubsub host a pubsub node name and a secret. The client can pass those to its XMPP server in the XEP-0357 enable request.
Example:
```xml
<iq from='example.net' to='steve@example.net/home' id='exec1' type='result'>
  <command xmlns='http://jabber.org/protocol/commands' sessionid='2015-06-15T01:05:03.380703Z' node='register-push-apns' status='completed'>
    <x xmlns='jabber:x:data' type='result'>
      <field var='jid'>
        <value>push.example.net</value>
      </field>
      <field var='node'>
        <value>2100994384</value>
      </field>
      <field var='secret'>
        <value>C46JMRFNEixmP1c5lXEUaIGKGVy-sv81</value>
      </field>
    </x>
  </command>
</iq>
```

### unregister command response
When a list of nodes was given in the request, the response contains the list of nodes of the deleted registrations.
Example:
```xml
<iq from='example.net' to='steve@example.net/home' id='exec1' type='result'>
  <command xmlns='http://jabber.org/protocol/commands' sessionid='2015-06-15T01:23:12.836386Z' node='unregister-push' status='completed'>
    <x xmlns='jabber:x:data' type='result'>
      <field type='list-multi' var='nodes'>
        <value>2100994384</value>
      </field>
    </x>
  </command>
</iq>
```

### list registrations
A list of a user's push-enabled clients can be obtained using the `list-push-registrations` command. This might be important if a push client shall be unregistered without having access to the device anymore. If a client provided a `device-name` value during registration it is included in the response along with the node name.
```xml
<iq from='example.net' to='bill@example.net/home' id='exec1' type='result'>
  <command xmlns='http://jabber.org/protocol/commands' sessionid='2015-08-13T16:10:02.489807Z' node='list-push-registrations' status='completed'>
    <x xmlns='jabber:x:data' type='result'>
      <item>
        <field var='device-name'><value>iOS device</value></field>
        <field var='node'><value>2269691389</value></field>
      </item>
      <item>
        <field var='device-name'><value>Ubuntu device</value></field>
        <field var='node'><value>2393247634</value></field>
      </item>
    </x>
  </command>
</iq>

```
