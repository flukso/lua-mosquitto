-- Test helper: per-test timeout.
--
-- A hanging publish blocks inside libmosquitto's C loop, so it cannot be
-- interrupted from Lua. Instead, fork a watchdog process for each test
-- that reports the test name, runs a cleanup function (e.g. to stop the
-- broker) and kills the test run if the test does not finish in time.

local busted = require("busted")
local signal = require("posix.signal")
local unistd = require("posix.unistd")
local wait = require("posix.sys.wait")

local M = {}

local function fullname(element)
	local names = {}
	while element and element.descriptor ~= "file" do
		table.insert(names, 1, element.name)
		element = busted.parent(element)
	end
	return table.concat(names, " ")
end

--- Kill the test run if a single test takes longer than `seconds`.
--- `cleanup` is called in the watchdog process before the run is killed.
function M.start(seconds, cleanup)
	local child

	local function disarm()
		if child then
			signal.kill(child, signal.SIGKILL)
			wait.wait(child)
			child = nil
		end
	end

	busted.subscribe({ "test", "start" }, function(element)
		disarm()
		local name = fullname(element)
		local runner = unistd.getpid()
		child = assert(unistd.fork())
		if child == 0 then
			unistd.sleep(seconds)
			io.stderr:write(("\n\nTIMEOUT: %q did not finish within %d seconds\n"):format(name, seconds))
			if cleanup then
				pcall(cleanup)
			end
			signal.kill(runner, signal.SIGKILL)
			unistd._exit(1)
		end
		return nil, true
	end)

	busted.subscribe({ "test", "end" }, function()
		disarm()
		return nil, true
	end)
end

return M
