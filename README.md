lua-mosquitto
=============

Lua bindings to the [libmosquitto](http://www.mosquitto.org/) client library.

The parameters to all functions are as per [libmosquitto's api](http://mosquitto.org/api)
only with sensible defaults for optional values, and return values directly
rather than via pointers.

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
        local mid = client:subscribe("complicated/topic", 2)
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
        local qos = 1
        local retain = true
        local mid = client:publish("my/topic/", "my payload", qos, retain)
end

client.ON_PUBLISH = function()
	client:disconnect()
end

broker = arg[1] -- defaults to "localhost" if arg not set
client:connect(broker)
client:loop_forever()
```

