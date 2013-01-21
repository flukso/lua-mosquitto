#!/usr/bin/env lua

if not arg[2] then
	print(string.format("Usage: %s <host> <node_id> <#nodes>", arg[0]))
	os.exit(1)
end

local nixio = require "nixio"
nixio.fs    = require "nixio.fs"
local mosq  = require "mosquitto"

local POLLIN          = nixio.poll_flags("in")
local POLLOUT         = nixio.poll_flags("out")

local POLL_TIMEOUT_MS = -1 -- no timeout

local TIMERFD_SEC     = 1
local TIMERFD_NS      = 0

local timer = {
	fd = nixio.timerfd(TIMERFD_SEC, TIMERFD_NS, TIMERFD_SEC, TIMERFD_NS),
	events = POLLIN,
	revents = 0
}

local MOSQ_NODE_ID       = arg[2]
local MOSQ_MAX_NODE      = arg[3]

local MOSQ_ID            = "flukso_" .. MOSQ_NODE_ID
local MOSQ_CLEAN_SESSION = true
local MOSQ_HOST          = arg[1]
local MOSQ_PORT          = 1883
local MOSQ_KEEPALIVE     = 300
local MOSQ_MAX_READ      = 10 -- packets
local MOSQ_MAX_WRITE     = 10 -- packets

mosq.init()
local mqtt = mosq.new(MOSQ_ID, MOSQ_CLEAN_SESSION)

--mqtt:set_callback(mosq.ON_CONNECT, function(...) print("CONNECT", ...) end)
--mqtt:set_callback(mosq.ON_DISCONNECT, function(...) print("DISCONNECT", ...) end)
--mqtt:set_callback(mosq.ON_PUBLISH, function(...) print("PUBLISH", ...) end)

mqtt:set_callback(mosq.ON_MESSAGE, function(mid, topic_in, message, qos, retain)
	local ttl = tonumber(message) - 1

	if ttl > 0 then
		local topic = "/node/" .. ((MOSQ_NODE_ID + 1) % MOSQ_MAX_NODE)
		mqtt:publish(topic, ttl, qos, retain)
	else
		local topic = "/done" 
		mqtt:publish(topic, ttl, 0, false)
	end
end)

--mqtt:set_callback(mosq.ON_SUBSCRIBE, function(...) print("SUBSCRIBE", ...) end)
--mqtt:set_callback(mosq.ON_UNSUBSCRIBE, function(...) print("UNSUBSCRIBE", ...) end)
--mqtt:set_callback(mosq.ON_LOG, function(...) print("LOG", ...) end)

while not mqtt:connect(MOSQ_HOST, MOSQ_PORT, MOSQ_KEEPALIVE) do
	print("trying to connect to broker ...")
end

mqtt:subscribe("/node/" .. MOSQ_NODE_ID .. "/#", 2)

local broker = {
	fd = nixio.fd_wrap(mqtt:socket()),
	events = POLLIN + POLLOUT,
	revents = 0
}

local fds = { timer, broker }

while true do
	local poll = nixio.poll(fds, POLL_TIMEOUT_MS)

	if not poll then -- poll == -1
	elseif poll == 0 then
	elseif poll > 0 then
		if nixio.bit.check(broker.revents, POLLIN) then
			mqtt:read(MOSQ_MAX_READ)
		end

		if nixio.bit.check(broker.revents, POLLOUT) and mqtt:want_write() then
			mqtt:write(MOSQ_MAX_WRITE)
		end

		if nixio.bit.check(timer.revents, POLLIN) then
			timer.fd:numexp() -- reset the numexp counter
			mqtt:misc()       -- mqtt housekeeping
		end
	end

	while (not mqtt:socket()) and (not mqtt:reconnect()) do
		print("trying to reconnect to broker ...")
		nixio.nanosleep(1, 0)
	end

	if mqtt:want_write() then
		broker.events = nixio.bit.set(broker.events, POLLOUT)
	else
		broker.events = nixio.bit.unset(broker.events, POLLOUT)
	end
end
