require("busted.runner")()

local helper = require("helpers.broker")
local HOST, TLS_HOST = helper.HOST, helper.TLS_HOST
local wait_for, spin = helper.wait_for, helper.spin

local broker

-- fail with the test name instead of hanging forever
require("helpers.watchdog").start(tonumber(os.getenv("SPEC_TIMEOUT")) or 10, function()
	if broker then
		broker:stop()
	end
end)

local mosquitto = require("mosquitto")

describe("mosquitto", function()
	-- clients created by a test, destroyed after it
	local clients

	local function new(...)
		local c = mosquitto.new(...)
		clients[#clients + 1] = c
		return c
	end

	-- A connected client. ON_CONNECT and ON_MESSAGE record into the
	-- returned state table: state.connack and state.msgs.
	local function connected(port, configure, host)
		local c = new()
		local state = { msgs = {} }
		c.ON_CONNECT = function(...)
			state.connack = { ... }
		end
		c.ON_MESSAGE = function(mid, topic, payload, qos, retain)
			state.msgs[#state.msgs + 1] = { mid = mid, topic = topic, payload = payload, qos = qos, retain = retain }
		end
		if configure then
			configure(c)
		end
		assert.is_true(c:connect(host or HOST, port or broker.port))
		assert.is_true(wait_for(c, function()
			return state.connack
		end))
		assert.same({ true, 0, "connection accepted" }, state.connack)
		return c, state
	end

	-- subscribe and wait for the SUBACK
	local function subscribe(c, topic, qos)
		local acked
		c.ON_SUBSCRIBE = function()
			acked = true
		end
		assert.is_number(c:subscribe(topic, qos))
		assert.is_true(wait_for(c, function()
			return acked
		end))
	end

	-- connect, run the loop until ON_CONNECT and return its arguments
	local function try_connect(c, port, host)
		local connack, disconnected
		c.ON_CONNECT = function(...)
			connack = { ... }
		end
		c.ON_DISCONNECT = function()
			disconnected = true
		end
		local ok, rc, msg = c:connect(host or HOST, port)
		if not ok then
			return nil, rc, msg
		end
		wait_for(c, function()
			return connack or disconnected
		end)
		return connack
	end

	setup(function()
		broker = helper.start()
	end)

	teardown(function()
		if broker then
			broker:stop()
			broker = nil
		end
	end)

	before_each(function()
		clients = {}
	end)

	after_each(function()
		for _, c in ipairs(clients) do
			-- destroyed clients have no methods left
			pcall(function()
				c:destroy()
			end)
		end
	end)

	describe("module", function()
		it("returns the library version", function()
			assert.matches("^%d+%.%d+%.%d+$", mosquitto.version())
		end)

		it("init and cleanup return true", function()
			assert.is_true(mosquitto.init())
			assert.is_true(mosquitto.cleanup())
			assert.is_true(mosquitto.init())
		end)

		it("defines constants", function()
			for _, name in ipairs({
				"ON_CONNECT",
				"ON_DISCONNECT",
				"ON_PUBLISH",
				"ON_MESSAGE",
				"ON_SUBSCRIBE",
				"ON_UNSUBSCRIBE",
				"ON_LOG",
				"LOG_NONE",
				"LOG_INFO",
				"LOG_NOTICE",
				"LOG_WARNING",
				"LOG_ERROR",
				"LOG_DEBUG",
				"LOG_ALL",
				"OPT_PROTOCOL_VERSION",
			}) do
				assert.is_number(mosquitto[name], name)
			end
			assert.equal(3, mosquitto.MQTT_PROTOCOL_V31)
			assert.equal(4, mosquitto.MQTT_PROTOCOL_V311)
			assert.equal(5, mosquitto.MQTT_PROTOCOL_V5)
		end)

		describe("topic_matches_sub", function()
			for _, case in ipairs({
				{ "a/b", "a/b", true },
				{ "a/+", "a/b", true },
				{ "a/#", "a/b/c", true },
				{ "#", "a/b", true },
				{ "a/+", "a/b/c", false },
				{ "a/b", "a/c", false },
			}) do
				it(("%s %s %s"):format(case[1], case[3] and "matches" or "does not match", case[2]), function()
					assert.equal(case[3], mosquitto.topic_matches_sub(case[1], case[2]))
				end)
			end

			it("raises on invalid subscription", function()
				assert.has_error(function()
					mosquitto.topic_matches_sub("a/#/b", "a/x/b")
				end)
			end)
		end)
	end)

	describe("new", function()
		it("returns a client", function()
			assert.is_userdata(new())
		end)

		it("accepts client id and clean session", function()
			assert.is_userdata(new("spec-id", false))
		end)

		it("requires clean session without client id", function()
			assert.has_error(function()
				new(nil, false)
			end)
		end)

		it("uses the given client id", function()
			local c = new("spec-new-client-id")
			assert.truthy(try_connect(c, broker.port))
			assert.truthy(broker:log():find("as spec-new-client-id", 1, true))
		end)
	end)

	describe("callbacks", function()
		it("can be set by name, constant or assignment", function()
			local c = new()
			local f = function() end
			assert.is_true(c:callback_set("ON_CONNECT", f))
			c.ON_PUBLISH = f
		end)

		it("can be set by constant", function()
			local called
			local c = new()
			assert.is_true(c:callback_set(mosquitto.ON_CONNECT, function()
				called = true
			end))
			assert.is_true(c:connect(HOST, broker.port))
			assert.is_true(wait_for(c, function()
				return called
			end))
		end)

		it("raises on unknown callback type", function()
			local c = new()
			assert.has_error(function()
				c:callback_set("ON_FOO", function() end)
			end)
			assert.has_error(function()
				c.LOG_INFO = function() end
			end)
			assert.has_error(function()
				c:callback_set(12345, function() end)
			end)
		end)

		it("raises when not given a function", function()
			local c = new()
			assert.has_error(function()
				c.ON_CONNECT = "not a function"
			end)
		end)

		it("can be replaced", function()
			local first, second
			local c = new()
			c.ON_CONNECT = function()
				first = true
			end
			c.ON_CONNECT = function()
				second = true
			end
			assert.is_true(c:connect(HOST, broker.port))
			assert.is_true(wait_for(c, function()
				return second
			end))
			assert.is_nil(first)
		end)

		it("ON_LOG receives level and message", function()
			local logs = {}
			local c = new()
			c.ON_LOG = function(level, msg)
				logs[#logs + 1] = { level, msg }
			end
			assert.truthy(try_connect(c, broker.port))
			assert.is_true(#logs > 0)
			assert.is_number(logs[1][1])
			assert.is_string(logs[1][2])
		end)
	end)

	describe("connect", function()
		it("calls ON_CONNECT on success", function()
			connected()
		end)

		it("accepts a keepalive", function()
			local c = new()
			assert.is_true(c:connect(HOST, broker.port, 5))
		end)

		it("connects asynchronously", function()
			local c = new()
			local connack
			c.ON_CONNECT = function(...)
				connack = { ... }
			end
			assert.is_true(c:connect_async(HOST, broker.port))
			assert.is_true(wait_for(c, function()
				return connack
			end))
			assert.same({ true, 0, "connection accepted" }, connack)
		end)

		it("returns an error when nothing listens on the port", function()
			local ok, rc, msg = new():connect(HOST, 1)
			assert.is_nil(ok)
			assert.is_number(rc)
			assert.is_string(msg)
		end)

		it("returns an error for an unresolvable host", function()
			local n, ok, rc, msg = (function(...)
				return select("#", ...), ...
			end)(new():connect("nonexistent.invalid", 1883))
			assert.equal(3, n)
			assert.is_nil(ok)
			assert.is_number(rc)
			assert.is_string(msg)
		end)

		it("can use MQTT v5", function()
			connected(nil, function(c)
				assert.is_true(c:option(mosquitto.OPT_PROTOCOL_VERSION, mosquitto.MQTT_PROTOCOL_V5))
			end)
		end)

		it("option raises on invalid value type", function()
			assert.has_error(function()
				new():option(mosquitto.OPT_PROTOCOL_VERSION, {})
			end)
		end)

		it("socket returns false when not connected and a fd when connected", function()
			local c = new()
			assert.is_false(c:socket())
			assert.is_true(c:connect(HOST, broker.port))
			assert.is_number(c:socket())
			assert.is_boolean(c:want_write())
		end)
	end)

	describe("disconnect", function()
		it("calls ON_DISCONNECT", function()
			local c = connected()
			local args
			c.ON_DISCONNECT = function(...)
				args = { ... }
			end
			assert.is_true(c:disconnect())
			assert.is_true(wait_for(c, function()
				return args
			end))
			assert.same({ true, 0, "client-initiated disconnect" }, args)
		end)

		it("calls ON_DISCONNECT when the broker drops the connection", function()
			local c = connected()
			local args
			c.ON_DISCONNECT = function(...)
				args = { ... }
			end
			-- the broker disconnects us when the oversized message arrives.
			-- publish may already notice the connection is lost.
			c:publish("drop", string.rep("x", helper.MAX_PACKET_SIZE + 1))
			wait_for(c, function()
				return args
			end, 5)
			assert.is_table(args)
			assert.is_false(args[1])
			assert.is_not.equal(0, args[2])
			assert.equal("unexpected disconnect", args[3])
		end)

		it("returns an error when the broker sends an invalid packet", function()
			local fake = helper.fake_broker()
			finally(fake.close)
			local c = new()
			local connected, args
			c.ON_CONNECT = function()
				connected = true
			end
			c.ON_DISCONNECT = function(...)
				args = { ... }
			end
			assert.is_true(c:connect(HOST, fake.port))
			fake.accept()
			fake.recv() -- CONNECT
			fake.send("\32\2\0\0") -- CONNACK, connection accepted
			assert.is_true(wait_for(c, function()
				return connected
			end))
			fake.send("\0\0") -- reserved packet type
			local ok, rc, msg
			local deadline = helper.now() + 2
			repeat
				ok, rc, msg = c:loop(10)
			until not ok or helper.now() > deadline
			assert.is_nil(ok)
			assert.equal(2, rc) -- MOSQ_ERR_PROTOCOL
			assert.is_string(msg)
			assert.is_false(args[1])
		end)

		it("returns an error when not connected", function()
			local ok, rc, msg = new():disconnect()
			assert.is_nil(ok)
			assert.equal(4, rc) -- MOSQ_ERR_NO_CONN
			assert.is_string(msg)
		end)

		it("can reconnect", function()
			local c = connected()
			local connects, disconnected = 0, false
			c.ON_CONNECT = function()
				connects = connects + 1
			end
			c.ON_DISCONNECT = function()
				disconnected = true
			end
			assert.is_true(c:disconnect())
			assert.is_true(wait_for(c, function()
				return disconnected
			end))
			assert.is_true(c:reconnect())
			assert.is_true(wait_for(c, function()
				return connects == 1
			end))
		end)

		it("can reconnect asynchronously", function()
			local c = connected()
			local connects, disconnected = 0, false
			c.ON_CONNECT = function()
				connects = connects + 1
			end
			c.ON_DISCONNECT = function()
				disconnected = true
			end
			assert.is_true(c:disconnect())
			assert.is_true(wait_for(c, function()
				return disconnected
			end))
			assert.is_true(c:reconnect_async())
			assert.is_true(wait_for(c, function()
				return connects == 1
			end))
		end)
	end)

	describe("publish and subscribe", function()
		it("returns errors when not connected", function()
			local c = new()
			for _, f in ipairs({ "publish", "subscribe", "unsubscribe", "loop" }) do
				local ok, rc, msg = c[f](c, f == "loop" and 10 or "topic")
				assert.is_nil(ok, f)
				assert.equal(4, rc, f) -- MOSQ_ERR_NO_CONN
				assert.is_string(msg, f)
			end
		end)

		it("subscribe returns mid and calls ON_SUBSCRIBE with granted qos", function()
			local c = connected()
			local args
			c.ON_SUBSCRIBE = function(...)
				args = { ... }
			end
			local mid = c:subscribe("sub/a", 1)
			assert.is_number(mid)
			assert.is_true(wait_for(c, function()
				return args
			end))
			assert.same({ mid, 1 }, args)
		end)

		for qos = 0, 2 do
			it("delivers a message with qos " .. qos, function()
				local c, state = connected()
				subscribe(c, "qos/" .. qos, 2)
				local published
				c.ON_PUBLISH = function(mid)
					published = mid
				end
				local mid = c:publish("qos/" .. qos, "hello", qos)
				assert.is_number(mid)
				assert.is_true(wait_for(c, function()
					return published and #state.msgs == 1
				end))
				assert.equal(mid, published)
				local m = state.msgs[1]
				assert.same({ "qos/" .. qos, "hello", qos, false }, { m.topic, m.payload, m.qos, m.retain })
				assert.is_number(m.mid)
			end)
		end

		it("delivers binary, empty, missing and large payloads", function()
			local c, state = connected()
			subscribe(c, "payload/#")
			local large = string.rep("0123456789abcdef", 64 * 1024) -- 1 MiB
			local payloads = { "a\0b\255\0", "", nil, large }
			for i = 1, 4 do
				assert.is_number(c:publish("payload/" .. i, payloads[i], 1))
			end
			assert.is_true(wait_for(c, function()
				return #state.msgs == 4
			end, 5))
			for i = 1, 4 do
				assert.equal("payload/" .. i, state.msgs[i].topic)
				assert.equal(payloads[i] or "", state.msgs[i].payload)
			end
		end)

		it("receives messages from other clients", function()
			local c, state = connected()
			subscribe(c, "external/#", 1)
			broker:pub("external/a", "from mosquitto_pub", 1)
			assert.is_true(wait_for(c, function()
				return #state.msgs == 1
			end))
			assert.same({ "external/a", "from mosquitto_pub", 1 }, {
				state.msgs[1].topic,
				state.msgs[1].payload,
				state.msgs[1].qos,
			})
		end)

		it("sets the retain flag", function()
			local c = connected()
			local published
			c.ON_PUBLISH = function()
				published = true
			end
			c:publish("retain/a", "kept", 1, true)
			assert.is_true(wait_for(c, function()
				return published
			end))

			local c2, state = connected()
			subscribe(c2, "retain/a")
			assert.is_true(wait_for(c2, function()
				return #state.msgs == 1
			end))
			assert.same({ "kept", true }, { state.msgs[1].payload, state.msgs[1].retain })
			-- clean up the retained message
			c:publish("retain/a", nil, 1, true)
			spin(c, 50)
		end)

		it("raises on invalid topic", function()
			local c = connected()
			assert.has_error(function()
				c:publish("bad/#", "x")
			end)
			assert.has_error(function()
				c:publish("bad/+", "x")
			end)
			assert.has_error(function()
				c:subscribe("bad/#/x")
			end)
		end)

		it("raises on invalid qos", function()
			local c = connected()
			assert.has_error(function()
				c:publish("x", "x", 3)
			end)
		end)

		it("unsubscribe stops delivery", function()
			local c, state = connected()
			subscribe(c, "unsub/a")
			subscribe(c, "unsub/marker")
			local unsubscribed
			c.ON_UNSUBSCRIBE = function(mid)
				unsubscribed = mid
			end
			local mid = c:unsubscribe("unsub/a")
			assert.is_number(mid)
			assert.is_true(wait_for(c, function()
				return unsubscribed
			end))
			assert.equal(mid, unsubscribed)
			c:publish("unsub/a", "not delivered", 1)
			c:publish("unsub/marker", "delivered", 1)
			assert.is_true(wait_for(c, function()
				return #state.msgs > 0
			end))
			spin(c, 50)
			assert.equal(1, #state.msgs)
			assert.equal("unsub/marker", state.msgs[1].topic)
		end)
	end)

	describe("will", function()
		-- make the broker drop the client so it publishes the will
		local function drop(c)
			local gone
			c.ON_DISCONNECT = function()
				gone = true
			end
			c:publish("drop", string.rep("x", helper.MAX_PACKET_SIZE + 1))
			wait_for(c, function()
				return gone
			end, 5)
		end

		it("is published when the connection is lost", function()
			local sub, state = connected()
			subscribe(sub, "will/#", 1)
			local c = connected(nil, function(c)
				assert.is_true(c:will_set("will/a", "gone", 1, false))
			end)
			drop(c)
			assert.is_true(wait_for(sub, function()
				return #state.msgs == 1
			end))
			assert.same({ "will/a", "gone", 1 }, { state.msgs[1].topic, state.msgs[1].payload, state.msgs[1].qos })
		end)

		it("is not published after will_clear", function()
			local sub, state = connected()
			subscribe(sub, "will/#")
			local c = connected(nil, function(c)
				assert.is_true(c:will_set("will/b", "gone", 1, false))
				assert.is_true(c:will_clear())
			end)
			drop(c)
			sub:publish("will/marker", "marker", 1)
			assert.is_true(wait_for(sub, function()
				return #state.msgs > 0
			end))
			spin(sub, 50)
			assert.equal(1, #state.msgs)
			assert.equal("will/marker", state.msgs[1].topic)
		end)

		it("raises on invalid topic", function()
			assert.has_error(function()
				new():will_set("will/#", "x")
			end)
		end)
	end)

	describe("authentication", function()
		it("succeeds with valid credentials", function()
			local c = new()
			assert.is_true(c:login_set(helper.USER, helper.PASSWORD))
			assert.same({ true, 0, "connection accepted" }, try_connect(c, broker.auth_port))
		end)

		it("is refused with wrong password", function()
			local c = new()
			assert.is_true(c:login_set(helper.USER, "wrong"))
			local connack = try_connect(c, broker.auth_port)
			assert.is_false(connack[1])
			assert.is_true(connack[2] == 4 or connack[2] == 5)
			assert.matches("^connection refused", connack[3])
		end)

		it("is refused without credentials", function()
			local c = new()
			local connack = try_connect(c, broker.auth_port)
			assert.is_false(connack[1])
			assert.equal(5, connack[2])
			assert.equal("connection refused - not authorised", connack[3])
		end)

		it("login_set accepts nil to clear credentials", function()
			local c = new()
			assert.is_true(c:login_set(helper.USER, helper.PASSWORD))
			assert.is_true(c:login_set(nil, nil))
			assert.is_false(try_connect(c, broker.auth_port)[1])
		end)
	end)

	describe("tls", function()
		-- libmosquitto 2.1 can raise SIGPIPE when a TLS connection is
		-- closed, which would kill the test runner
		local psignal = require("posix.signal")
		local old_sigpipe

		setup(function()
			old_sigpipe = psignal.signal(psignal.SIGPIPE, psignal.SIG_IGN)
		end)

		teardown(function()
			psignal.signal(psignal.SIGPIPE, old_sigpipe or psignal.SIG_DFL)
		end)

		-- true if a connection with the given configuration is accepted
		local function tls_connect(port, host, configure)
			local c = new()
			configure(c)
			local connack = try_connect(c, port, host)
			return connack and connack[1] or false
		end

		it("connects with the right CA", function()
			assert.is_true(tls_connect(broker.tls_port, TLS_HOST, function(c)
				assert.is_true(c:tls_set(broker.ca))
			end))
		end)

		it("fails with the wrong CA", function()
			assert.is_false(tls_connect(broker.tls_port, TLS_HOST, function(c)
				assert.is_true(c:tls_set(broker.other_ca))
			end))
		end)

		it("authenticates with a client certificate", function()
			assert.is_true(tls_connect(broker.cert_port, TLS_HOST, function(c)
				assert.is_true(c:tls_set(broker.ca, nil, broker.client_cert, broker.client_key))
			end))
		end)

		it("fails without client certificate when one is required", function()
			assert.is_false(tls_connect(broker.cert_port, TLS_HOST, function(c)
				assert.is_true(c:tls_set(broker.ca))
			end))
		end)

		it("verifies the server hostname", function()
			assert.is_false(tls_connect(broker.tls_port, HOST, function(c)
				assert.is_true(c:tls_set(broker.ca))
			end))
		end)

		it("tls_insecure_set skips the hostname check", function()
			assert.is_true(tls_connect(broker.tls_port, HOST, function(c)
				assert.is_true(c:tls_set(broker.ca))
				assert.is_true(c:tls_insecure_set(true))
			end))
		end)

		it("tls_opts_set sets the TLS version", function()
			assert.is_true(tls_connect(broker.tls_port, TLS_HOST, function(c)
				assert.is_true(c:tls_set(broker.ca))
				assert.is_true(c:tls_opts_set(true, "tlsv1.2"))
			end))
		end)

		it("tls_opts_set raises on invalid TLS version", function()
			assert.has_error(function()
				new():tls_opts_set(true, "sslv1")
			end)
		end)

		it("raises on missing CA file", function()
			assert.has_error(function()
				new():tls_set("/nonexistent/ca.crt")
			end)
		end)

		it("connects with a pre-shared key", function()
			assert.is_true(tls_connect(broker.psk_port, HOST, function(c)
				assert.is_true(c:tls_psk_set(helper.PSK_KEY, helper.PSK_IDENTITY))
			end))
		end)

		it("fails with the wrong pre-shared key", function()
			assert.is_false(tls_connect(broker.psk_port, HOST, function(c)
				assert.is_true(c:tls_psk_set("fedcba9876543210", helper.PSK_IDENTITY))
			end))
		end)
	end)

	describe("loop", function()
		it("loop_forever returns after disconnect", function()
			local c = new()
			local published
			c.ON_CONNECT = function()
				c:publish("forever", "x", 1)
			end
			c.ON_PUBLISH = function()
				published = true
				c:disconnect()
			end
			assert.is_true(c:connect(HOST, broker.port))
			assert.is_true(c:loop_forever(100))
			assert.is_true(published)
		end)

		it("can be driven with loop_read, loop_write and loop_misc", function()
			local poll = require("posix.poll")
			local c = new()
			local state = { msgs = {} }
			c.ON_CONNECT = function()
				c:subscribe("manual", 1)
			end
			c.ON_SUBSCRIBE = function()
				c:publish("manual", "manual loop", 1)
			end
			c.ON_MESSAGE = function(_, topic, payload)
				state.msgs[#state.msgs + 1] = { topic, payload }
			end
			assert.is_true(c:connect(HOST, broker.port))
			local deadline = helper.now() + 2
			while #state.msgs == 0 and helper.now() < deadline do
				local fd = c:socket()
				assert.is_number(fd)
				local fds = { [fd] = { events = { IN = true, OUT = c:want_write() } } }
				if poll.poll(fds, 10) > 0 then
					if fds[fd].revents.IN then
						assert.is_true(c:loop_read())
					end
					if fds[fd].revents.OUT then
						assert.is_true(c:loop_write())
					end
				end
				assert.is_true(c:loop_misc())
			end
			assert.same({ { "manual", "manual loop" } }, state.msgs)
		end)

		it("loop_start and loop_stop run a network thread", function()
			local c = new()
			assert.is_true(c:connect(HOST, broker.port))
			assert.is_true(c:loop_start())
			helper.sleep_ms(50)
			assert.is_true(c:disconnect())
			assert.is_true(c:loop_stop(true))
		end)

		it("threaded_set returns true", function()
			local c = new()
			assert.is_true(c:threaded_set(true))
			assert.is_true(c:threaded_set(false))
		end)
	end)

	describe("lifecycle", function()
		it("destroy removes all methods", function()
			local c = new()
			assert.is_true(c:destroy())
			assert.has_error(function()
				c:connect(HOST, broker.port)
			end)
		end)

		it("garbage collects destroyed and connected clients", function()
			do
				local c = mosquitto.new()
				c:destroy()
				local c2 = mosquitto.new()
				c2.ON_CONNECT = function() end
				assert.is_true(c2:connect(HOST, broker.port))
			end
			collectgarbage()
			collectgarbage()
		end)

		it("reinitialise resets the client", function()
			local c = new()
			local called
			c.ON_CONNECT = function()
				called = true
			end
			assert.is_true(c:reinitialise("spec-reinit", true))
			assert.is_true(c:connect(HOST, broker.port))
			spin(c, 100)
			assert.is_nil(called)
			assert.truthy(broker:log():find("as spec-reinit", 1, true))
		end)

		it("reinitialise requires clean session without client id", function()
			local c = new()
			assert.has_error(function()
				c:reinitialise(nil, false)
			end)
		end)
	end)
end)
