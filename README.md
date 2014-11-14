lua-mosquitto
=============

Lua bindings to the [libmosquitto](http://www.mosquitto.org/) client library.


Compile
-------
You need Lua and mosquitto development packages (headers and libs) to
build lua-mosquitto.

Compile with

    make

You can override the pkg-config package name to set a specific Lua version.
For example:

    make LUAPKGC=lua5.2

Example usage
-------------

Here is a very simple example that subscribes to the broker $SYS topic tree
and prints out the resulting messages:

```Lua
mqtt = require("mosquitto")
client = mqtt.new()

client.ON_CONNECT = function()
        print("connected")
        client:subscribe("$SYS/#")
end

client.ON_MESSAGE = function(mid, topic, payload)
        print(topic, payload)
end

broker = arg[1] -- defaults to "localhost" if arg not set
client:connect(broker)
client:loop_forever()
```

Here is another simple example that will just publish a single message,
"hello", to the topic "world" and then disconnect.

```Lua
mqtt = require("mosquitto")
client = mqtt.new()

client.ON_CONNECT = function()
        client:publish("world", "hello")
end

client.ON_PUBLISH = function()
	client:disconnect()
end

broker = arg[1] -- defaults to "localhost" if arg not set
client:connect(broker)
client:loop_forever()
```

