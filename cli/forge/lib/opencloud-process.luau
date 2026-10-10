--!strict
local task = require("@lune/task")
local Deadline = require("./deadline")
local M = {}

-- Readers have no close method in Lune 0.10.5. Drain both to EOF, close
-- stdin, and observe status; cancellation alone is never cleanup evidence.
function M.exchange(child: any, input: string, arm: ((() -> ()) -> () -> ())?): any
	local waiter = coroutine.running()
	local settled, waiting = false, false
	local state: any = { stdout = "", stderr = "", expired = false, residual = true }
	local workers: { thread } = {}
	local reap: Deadline.Disarm? = nil
	local disarm: Deadline.Disarm? = nil
	local function finish()
		if settled then
			return
		end
		settled = true
		if waiting then
			task.defer(waiter)
		end
	end
	local function complete()
		if state.statusDone and state.stdoutDone and state.stderrDone and state.stdinDone then
			state.residual = not (state.status and state.stdoutEOF and state.stderrEOF and state.stdinClosed)
			finish()
		end
	end
	local function terminate()
		if state.killAttempted then
			return
		end
		state.killAttempted = true
		local killed = pcall(function()
			child:kill()
		end)
		state.killFailed = not killed
		reap = Deadline.arm(5, function()
			state.reapFailed = true
			state.residual = true
			finish()
		end)
	end
	local function expire()
		if settled then
			return
		end
		state.expired = true
		terminate()
	end
	-- Arm before touching a pipe, so startup/write stalls are covered too.
	if arm then
		disarm = arm(expire)
	else
		disarm = Deadline.arm(35, expire)
	end
	table.insert(
		workers,
		task.spawn(function()
			local ok, status = pcall(function()
				return child:status()
			end)
			if ok and type(status) == "table" and type(status.code) == "number" and type(status.ok) == "boolean" then
				state.status = status
			else
				state.statusFailed = true
				terminate()
			end
			state.statusDone = true
			complete()
		end)
	)
	for _, stream in { "stdout", "stderr" } do
		table.insert(
			workers,
			task.spawn(function()
				local ok = pcall(function()
					while true do
						local chunk = child[stream]:read(4096)
						if chunk == nil then
							state[stream .. "EOF"] = true
							break
						end
						if stream == "stdout" then
							if #state.stdout + #chunk > 65536 then
								error("protocol limit")
							end
							state.stdout ..= chunk
						else
							local room = 65536 - #state.stderr
							if room > 0 then
								state.stderr ..= string.sub(chunk, 1, room)
							end
						end
					end
				end)
				if not ok then
					state.pipeFailed = true
					terminate()
				end
				state[stream .. "Done"] = true
				complete()
			end)
		)
	end
	table.insert(
		workers,
		task.spawn(function()
			local written = pcall(function()
				child.stdin:write(input)
			end)
			local closed = pcall(function()
				child.stdin:close()
			end)
			state.stdinClosed = closed
			state.stdinDone = true
			if not written or not closed then
				state.pipeFailed = true
				terminate()
			end
			complete()
		end)
	)
	if not settled then
		waiting = true
		coroutine.yield()
	end
	if disarm then
		disarm()
	end
	if reap then
		reap()
	end
	for _, worker in workers do
		pcall(task.cancel, worker)
	end
	-- Last close attempt is local-only; a failure remains visible.
	if not state.stdinClosed then
		state.stdinClosed = pcall(function()
			child.stdin:close()
		end)
	end
	state.cleaned = not state.residual and not state.killFailed and not state.pipeFailed and not state.statusFailed
	return state
end

return M
