-- Test helper: runs a private mosquitto broker with a set of listeners
-- (anonymous, password auth, TLS, TLS with client certificates, TLS-PSK)
-- and provides helpers to drive lua-mosquitto clients against it.

local fcntl = require("posix.fcntl")
local signal = require("posix.signal")
local socket = require("posix.sys.socket")
local ptime = require("posix.time")
local unistd = require("posix.unistd")
local wait = require("posix.sys.wait")

local M = {}

M.HOST = "127.0.0.1"
-- the name in the server certificate. It deliberately does not contain
-- HOST, so connecting to HOST over TLS needs tls_insecure_set(true)
M.TLS_HOST = "localhost"
M.USER, M.PASSWORD = "testuser", "testpass"
M.PSK_IDENTITY, M.PSK_KEY = "psk-client", "0123456789abcdef"
-- the broker disconnects clients that send bigger packets
M.MAX_PACKET_SIZE = 2 * 1024 * 1024

local function sh(cmd)
	local ok = os.execute(cmd)
	if ok ~= true and ok ~= 0 then
		error("command failed: " .. cmd, 2)
	end
end

local function readall(cmd)
	local f = assert(io.popen(cmd))
	local out = f:read("*a")
	f:close()
	return out
end

local function writefile(path, content)
	local f = assert(io.open(path, "w"))
	f:write(content)
	f:close()
end

--- Monotonic time in seconds.
function M.now()
	local t = ptime.clock_gettime(ptime.CLOCK_MONOTONIC)
	return t.tv_sec + t.tv_nsec / 1e9
end

function M.sleep_ms(ms)
	ptime.nanosleep({ tv_sec = math.floor(ms / 1000), tv_nsec = (ms % 1000) * 1e6 })
end

local function tcp_socket()
	return assert(socket.socket(socket.AF_INET, socket.SOCK_STREAM, 0))
end

local function free_port()
	local fd = tcp_socket()
	assert(socket.bind(fd, { family = socket.AF_INET, addr = M.HOST, port = 0 }))
	local port = assert(socket.getsockname(fd)).port
	unistd.close(fd)
	return port
end

local function port_open(port)
	local fd = tcp_socket()
	local ok = socket.connect(fd, { family = socket.AF_INET, addr = M.HOST, port = port })
	unistd.close(fd)
	return ok == 0
end

local function gen_certs(dir)
	local q = " >/dev/null 2>&1"
	local key = "-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes"
	writefile(dir .. "/server.ext", "subjectAltName=DNS:" .. M.TLS_HOST .. "\n")
	sh(("cd %s && openssl req -x509 %s -keyout ca.key -out ca.crt -days 1 -subj /CN=test-ca%s"):format(dir, key, q))
	for _, name in ipairs({ "server", "client" }) do
		sh(("cd %s && openssl req %s -keyout %s.key -out %s.csr -subj /CN=%s%s"):format(dir, key, name, name, name, q))
		sh(
			("cd %s && openssl x509 -req -in %s.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -out %s.crt %s%s"):format(
				dir,
				name,
				name,
				name == "server" and "-extfile server.ext" or "",
				q
			)
		)
	end
	-- a second CA that did not sign the server cert
	sh(("cd %s && openssl req -x509 %s -keyout other-ca.key -out other-ca.crt -days 1 -subj /CN=other-ca%s"):format(dir, key, q))
end

-- Run mosquitto as a child process rather than daemonized so we know its
-- pid, and Ctrl-C reaches it too. Startup warnings go to <name>.stderr.
local function spawn_broker(dir, name)
	local pid = assert(unistd.fork())
	if pid == 0 then
		local fd = fcntl.open(dir .. "/" .. name .. ".stderr", fcntl.O_WRONLY + fcntl.O_CREAT + fcntl.O_TRUNC, 420)
		if fd then
			unistd.dup2(fd, 1)
			unistd.dup2(fd, 2)
		end
		unistd.execp("mosquitto", { "-c", dir .. "/" .. name .. ".conf" })
		unistd._exit(127)
	end
	return pid
end

local Broker = {}
Broker.__index = Broker

--- Start a broker. Returns an object with the ports and file paths.
function M.start()
	local self = setmetatable({}, Broker)
	self.dir = readall("mktemp -d"):gsub("%s+$", "")
	local d = self.dir
	self.port, self.auth_port = free_port(), free_port()
	self.tls_port, self.cert_port, self.psk_port = free_port(), free_port(), free_port()
	self.ca, self.other_ca = d .. "/ca.crt", d .. "/other-ca.crt"
	self.client_cert, self.client_key = d .. "/client.crt", d .. "/client.key"

	gen_certs(d)
	sh(("mosquitto_passwd -b -c %s/passwd %s %s >/dev/null"):format(d, M.USER, M.PASSWORD))
	writefile(d .. "/psk", M.PSK_IDENTITY .. ":" .. M.PSK_KEY .. "\n")
	sh(("chmod 600 %s/passwd %s/psk"):format(d, d))

	local tls = ("cafile %s\ncertfile %s/server.crt\nkeyfile %s/server.key\n"):format(self.ca, d, d)
	local common = {
		"persistence false",
		-- queue QoS 0 for offline persistent subscribers
		"queue_qos0_messages true",
		"max_packet_size " .. M.MAX_PACKET_SIZE,
	}
	-- The password protected listener runs in a separate broker. Mixing
	-- it with anonymous listeners would need per_listener_settings, which
	-- in mosquitto 2.0 stops messages from being queued for offline
	-- clients.
	writefile(
		d .. "/mosquitto.conf",
		table.concat(common, "\n")
			.. "\n"
			.. table.concat({
				"log_dest file " .. d .. "/mosquitto.log",
				"log_type all",
				"allow_anonymous true",
				"psk_file " .. d .. "/psk",
				("listener %d %s"):format(self.port, M.HOST),
				("listener %d %s\n%s"):format(self.tls_port, M.HOST, tls),
				("listener %d %s\nrequire_certificate true\n%s"):format(self.cert_port, M.HOST, tls),
				("listener %d %s\npsk_hint spec"):format(self.psk_port, M.HOST),
				"",
			}, "\n")
	)
	writefile(
		d .. "/auth.conf",
		table.concat(common, "\n")
			.. "\n"
			.. table.concat({
				"log_dest file " .. d .. "/auth.log",
				"allow_anonymous false",
				"password_file " .. d .. "/passwd",
				("listener %d %s"):format(self.auth_port, M.HOST),
				"",
			}, "\n")
	)

	self.pids = {}
	local brokers = { { "mosquitto", self.port }, { "auth", self.auth_port } }
	for _, b in ipairs(brokers) do
		self.pids[#self.pids + 1] = spawn_broker(d, b[1])
	end

	local ready = 0
	for _ = 1, 100 do
		ready = 0
		for i, b in ipairs(brokers) do
			if port_open(b[2]) then
				ready = ready + 1
			elseif wait.wait(self.pids[i], wait.WNOHANG) == self.pids[i] then
				self.pids[i] = false -- exited
			end
		end
		if ready == #brokers then
			return self
		end
		M.sleep_ms(50)
	end
	local msg = ""
	for _, b in ipairs(brokers) do
		local f = io.open(d .. "/" .. b[1] .. ".stderr")
		if f then
			msg = msg .. f:read("*a")
			f:close()
		end
	end
	self:stop()
	error("mosquitto did not start: " .. msg)
end

function Broker:stop()
	for i, pid in ipairs(self.pids or {}) do
		if pid then
			signal.kill(pid, signal.SIGTERM)
			wait.wait(pid)
			self.pids[i] = false
		end
	end
	os.execute("rm -rf '" .. self.dir .. "'")
end

--- Contents of the anonymous broker's log file.
function Broker:log()
	local f = assert(io.open(self.dir .. "/mosquitto.log"))
	local log = f:read("*a")
	f:close()
	return log
end

--- Publish a message with the mosquitto_pub command line client, so
--- incoming messages are not produced by the code under test.
function Broker:pub(topic, payload, qos, retain)
	sh(("mosquitto_pub -h %s -p %d -t '%s' -m '%s' -q %d %s"):format(
		M.HOST,
		self.port,
		topic,
		payload,
		qos or 0,
		retain and "-r" or ""
	))
end

--- Run the client's network loop until cond() returns true, the
--- connection is lost or `timeout` seconds pass. Returns cond().
function M.wait_for(client, cond, timeout)
	local deadline = M.now() + (timeout or 2)
	while not cond() and M.now() < deadline do
		if not client:loop(10) then
			break
		end
	end
	return cond() and true or false
end

--- Run the client's network loop for `ms` milliseconds.
function M.spin(client, ms)
	local deadline = M.now() + ms / 1000
	while M.now() < deadline do
		if not client:loop(10) then
			break
		end
	end
end

return M
