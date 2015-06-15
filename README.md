#mod_push
mod_push implements [XEP-0357 (Push)](http://www.xmpp.org/extensions/xep-0357.html)
for ejabberd and includes a messaging-focussed app server for the common push
notification services. These are
* [APNS (Apple push notification service)](https://developer.apple.com/library/ios/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/ApplePushService.html)
* [GCM (Google cloud messaging)](https://developers.google.com/cloud-messaging)
* [Mozilla SimplePush](https://wiki.mozilla.org/WebAPI/SimplePush)
* [Ubuntu Push](https://developer.ubuntu.com/en/start/platform/guides/push-notifications-client-guide)
* [WNS (Windows notification service)](https://msdn.microsoft.com/en-us//library/windows/apps/hh913756.aspx)

mod_push is a project in the Google Summer of Code 2015 and is still pre-alpha. Please send feedback.

##Prerequisites
* Erlang/OTP 17 or higher
* If app server backends are used a working starttls configuration is required; by default the certificate set by the 'certfile' option will be used for communication with the push providers
* for using APNS [this OTP fix](https://github.com/processone/otp/commit/45aaefe739c8ea6c33d140d056b94fcf53c3df30) is needed (see [this blog post](https://blog.process-one.net/apple-increasing-security-of-push-service-ahead-of-wwdc))
* for now an [ejabberd branch](https://github.com/royneary/ejabberd/tree/mod_push_adjustments) with mod_push-specific modifications is needed

##Installation
```bash
git clone https://github.com/royneary/mod_push.git
# copy the source code folder to the module sources folder of your ejabberd
# installation (may be different on your machine)
sudo cp -R mod_push /var/spool/jabber/.ejabberd-modules/sources/
# if done right ejabberd will list mod_push as available module
ejabberdctl modules_available
# automatically compile and install mod_push
ejabberdctl module_install mod_push 
```

##Configuration
###resume_timeout
mod_push depends on stream management (XEP-0198) stream resumption. So the
option 'resume_timeout' for module ejabberd_c2s in the listen-section of
ejabberd.yml must be set to a value > 0 (default value is 300). This enables
stream resumption but the value has no effect on push users since mod_push
overwrites this value to keep them pending for a long time.

###pubsub configuration
An XEP-0357 app server requires a pubsub service where XMPP servers can publish
notifications. The pubsub service needs a dedicated host with a virtual nodetree and the
'push' plugin:
```yaml
mod_pubsub:
  host : "push.example.net"
  nodetree : "virtual"
  plugins: 
    - "push"
```
If you want to allow other XMPP servers to use your app server you need a SRV record in your DNS server:
```fundamental
_xmpp-server._tcp.push.example.net. 86400 IN SRV 5 0 5269 example.net.
```

###XEP-0357 configuration
There are user-definable config options to specify what contents should be in
a push notification. You can set default values for them in the mod_push
section:
* include_senders: include the jids of the last message sender and the last subscription sender (default: false)
* include_message_count: include the number of queued messages (default: true)
* include_subscription_count: include the number of queued subscription requests (default: true)
* include_message_bodies: include the message contents (default: false)

example:
```yaml
mod_push:
  include_senders: true
  include_message_count: true
  include_subscription_count: true
```

###App server configuration
You can set up multiple app server backends for the different push
notification services. This is not required, your users can use external app
servers too. 

####Common options
* register_host: the app server host where users can register. Should be the XMPP server host, so users don't have to guess it (no service discovery implemented yet).
* pubsub_host: the pubsub_host of the backend
* type: apns|gcm|mozilla|ubuntu|wns
* app_name: the name of the app the backend is configured for, will be send to the user when service discovery is done on the register_host; the default value is "any", but that's only a valid value for backend types that don't require developer credentials, that is ubuntu and mozilla

####APNS-specific options
* certfile: path to a pem file containing the developer's private key and the certificate obtained from Apple during the provisioning procedure

####GCM-specific options
* auth_key: the API key obtained from Google's api console

####WNS
TBD

###Example configuration
```yaml
mod_pubsub:
  host : "push.myserver.net"
  nodetree : "virtual"
  plugins: 
    - "push"

mod_push:
  include_senders: true
  backends:
    -
      type: ubuntu
      register_host: "example.net"
      pubsub_host: "push.example.net"
    -
      type: gcm
      register_host: "example.net"
      pubsub_host: "push.example.net"
      auth_key: "HgeGfbhwplu7F-fjCUf6gBfkauUaq12h0nHazqc" 
    -
      type: apns
      register_host: "example.net"
      pubsub_host: "push.example.net"
      certfile: "/etc/ssl/private/apns_example_app.pem"  
```

##App server usage
Clients can register by sending adhoc requests containing a data form with the 'urn:xmpp:push:options' FORM_TYPE.
These are the available adhoc commands:
* register-push-apns: register at an APNS backend
* register-push-gcm: register at a GCM backend
* register-push-mozilla: register at a Mozilla SimplePush backend
* register-push-ubuntu: register at an Ubuntu Push backend
* register-push-wns: register at a WNS backend
* list-push-registrations: request a list of all registrations of the requesting user
* unregister-push: delete the user's registrations (all of them or those matching a given list of node names)

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

###Common fields for the register commands
* token: the device identifier the client obtained from the push service
* device-id: a device identifier a client can define explicitly (the jid's resource part will be used otherwise)
* device-name: an optional name that will be included in the response to the list-push-registrations command

###register-push-apns fields
* token: the base64-encoded binary token obtained from APNS
* silent-push: when set to true content-available will be set to 1, default vaule: false

###register-push-ubuntu fields
* application-id: the app id as registered at Ubuntu's push service

###register-push-wns fields
* silent-push: TBD

###unregister-push fields
* device-id: Either device ID or a list of node IDs must be given. If none of these are in the payload, the resource of the from jid will be interpreted as device ID. If both device ID and node list are given, the device ID will be ignored and only registrations matching a node ID in the given list will be removed.
* nodes: a list of node names; registrations mathing one of them will be removed

###register command response
The app server returns the jid of the pubsub host and a pubsub node name. The client can pass those to its XMPP server in the XEP-0357 enable request.
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
    </x>
  </command>
</iq>
```

###unregister command response
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
