lua-mosquitto
=============

Lua bindings to the [libmosquitto](http://www.mosquitto.org/) client library.

The parameters to all functions are as per [libmosquitto's api](http://mosquitto.org/api)
only with sensible defaults for optional values, and return values directly
rather than via pointers.

Generated API documentation for the lua functions [is also available](docs/)
([Direct link if you are within github](https://flukso.github.io/lua-mosquitto/docs))

Compile
-------
You need Lua and mosquitto development packages (headers and libs) to
build lua-mosquitto.

Compile with

    make

You can override the pkg-config package name to set a specific Lua version.
For example:

    make LUAPKG=lua5.2

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


Callbacks
---------

Callbacks are called from the client method that calls into libmosquitto,
usually `loop()`, and run in the same coroutine. An error in a callback
is raised from that method once libmosquitto has returned.

With `loop_start()`, libmosquitto runs the network loop in its own thread
and calls the callbacks from there. A Lua state must not be used by two
threads at the same time, so this is only safe if no other Lua code runs
in the same Lua state meanwhile, which is rarely the case. Use `loop()`
or `loop_forever()` instead, or integrate the client in your own event
loop with `socket()`, `want_write()`, `loop_read()`, `loop_write()` and
`loop_misc()`. This also applies to Lua threads in separate Lua states,
like Lua Lanes: run the loop in the thread that owns the client.


Testing
-------
The tests need [busted](https://lunarmodules.github.io/busted/),
luaposix, mosquitto, mosquitto_pub, mosquitto_passwd and openssl. They
build the module under `.build/<lua>/` and start a private mosquitto
broker on free ports.

    make check                 # run tests with lua5.5
    make check LUA=luajit      # pick another interpreter
    make check-all             # run with all supported Lua versions
