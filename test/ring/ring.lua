#!/usr/bin/env lua

if not arg[3] then
	print(string.format("Usage: %s <host> <#nodes> <#messages> <ttl>", arg[0]))
	os.exit(1)
end

local nixio = require "nixio"
nixio.fs    = require "nixio.fs"
local mosq  = require "mosquitto"

local POLLIN          = nixio.poll_flags("in")
local POLLOUT         = nixio.poll_flags("out")
local POLLNVAL        = nixio.poll_flags("nval")

local POLL_TIMEOUT_MS = -1 -- no timeout

local TIMERFD_SEC     = 1
local TIMERFD_NS      = 0

local timer = {
	fd = nixio.timerfd(TIMERFD_SEC, TIMERFD_NS, TIMERFD_SEC, TIMERFD_NS),
	events = POLLIN,
	revents = 0
}

local MOSQ_MAX_NODE      = arg[2]
local MOSQ_MAX_MSG       = arg[3]
local MOSQ_TTL           = arg[4]
local MOSQ_INFLIGHT_MSG  = MOSQ_MAX_MSG
local MOSQ_START_SEC, MOSQ_START_USEC

local MOSQ_ID            = "flukso"
local MOSQ_CLEAN_SESSION = true
local MOSQ_HOST          = arg[1]
local MOSQ_PORT          = 1883
local MOSQ_KEEPALIVE     = 300
local MOSQ_MAX_READ      = 100 -- packets
local MOSQ_MAX_WRITE     = 100 -- packets

mosq.init()
local mqtt = mosq.new(MOSQ_ID, MOSQ_CLEAN_SESSION)
--[[
mqtt:set_callback(mosq.ON_CONNECT, function(...)
	-- inject #messages into the ring
	for i = 0, MOSQ_MAX_MSG - 1 do
    	mqtt:publish("/node/0", MOSQ_TTL, 0, false)
	end
end)
]]--
--mqtt:set_callback(mosq.ON_DISCONNECT, function(...) print("DISCONNECT", ...) end)
--mqtt:set_callback(mosq.ON_PUBLISH, function(...) print("PUBLISH", ...) end)

mqtt:set_callback(mosq.ON_MESSAGE, function(...)
	local sec, usec = nixio.gettimeofday()
	MOSQ_INFLIGHT_MSG = MOSQ_INFLIGHT_MSG - 1

	print(string.format("%d in-flight messages remaining at %d sec %6d usec", MOSQ_INFLIGHT_MSG, sec, usec))

	if MOSQ_INFLIGHT_MSG == 0 then
		local elapsed_sec = sec - MOSQ_START_SEC
		local elapsed_msec = math.floor((usec - MOSQ_START_USEC) / 1e3)
		if elapsed_msec < 0 then
			elapsed_sec = elapsed_sec - 1
			elapsed_msec = 1e3 + elapsed_msec
		end

		print(string.format("Elapsed time: %d.%03d sec", elapsed_sec, elapsed_msec))
		print(string.format("Throughput: %d msg/sec", math.floor((MOSQ_MAX_MSG * MOSQ_TTL) / (elapsed_sec + elapsed_msec / 1e3))))
		-- clean up the parent and all forked ring processes
		nixio.kill(0, nixio.const.SIGTERM)
	end
end)

--mqtt:set_callback(mosq.ON_SUBSCRIBE, function(...) print("SUBSCRIBE", ...) end)
--mqtt:set_callback(mosq.ON_UNSUBSCRIBE, function(...) print("UNSUBSCRIBE", ...) end)
--mqtt:set_callback(mosq.ON_LOG, function(...) print("LOG", ...) end)

while not mqtt:connect(MOSQ_HOST, MOSQ_PORT, MOSQ_KEEPALIVE) do
	print("trying to connect to broker ...")
end

mqtt:subscribe("/done/#", 2)

local broker = {
	fd = nixio.fd_wrap(mqtt:socket()),
	events = POLLIN + POLLOUT,
	revents = 0
}

local fds = { timer, broker }

-- fork #nodes
for i = 0, MOSQ_MAX_NODE - 1 do
	local pid = nixio.fork()

	if pid == 0 then -- child process
		nixio.exec("node.lua", MOSQ_HOST, i, MOSQ_MAX_NODE)
	end

	nixio.nanosleep(0, 20000000) -- 20ms
end

-- sleep for a while to allow all forked processes to settle down
nixio.nanosleep(math.floor(MOSQ_MAX_NODE / 5), 0)

MOSQ_START_SEC, MOSQ_START_USEC = nixio.gettimeofday()
print(string.format("Sending %d messages with ttl %d into a ring of %d nodes", MOSQ_MAX_MSG, MOSQ_TTL, MOSQ_MAX_NODE))
print(string.format("Starting at %d sec %d usec", MOSQ_START_SEC, MOSQ_START_USEC))

-- inject #messages into the ring
for i = 0, MOSQ_MAX_MSG - 1 do
	mqtt:publish("/node/0", MOSQ_TTL, 0, false)
end

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
