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
notifications. If you want to allow other XMPP servers to use your app server
you have to configure a dedicated pubsub host with a virtual nodetree and the
'push' plugin:
```yaml
mod_pubsub:
  host : "push.example.net"
  nodetree : "virtual"
  plugins: 
    - "push"
```
For the pubsub host to be reachable you need a SRV record in your DNS server:
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

####APNS
TBD

####GCM
TBD

####Mozilla SimplePush
TBD

####Ubuntu Push
TBD

####WNS
TBD
