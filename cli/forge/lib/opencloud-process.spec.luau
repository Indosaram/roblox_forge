--!strict
local process = require("@lune/process")
local Deadline = require("./deadline")
local lifecycle = require("./opencloud-process")

return {
	["owned helper exit drains both pipes and observes exit status"] = function()
		local child = process.create("bun", { "cli/forge/lib/opencloud-process.fixture.mjs", "exit" })
		local state = lifecycle.exchange(child, "fixture input")
		assert(
			state.cleaned and not state.residual and state.status.ok,
			"state.cleaned and not state.residual and state.status.ok"
		)
		assert(
			state.stdinClosed and state.stdoutEOF and state.stderrEOF,
			"state.stdinClosed and state.stdoutEOF and state.stderrEOF"
		)
		assert(string.find(state.stdout, "DONE", 1, true))
	end,
	["owned helper deadline kills and reaps after exact stdout barrier"] = function()
		local child = process.create("bun", { "cli/forge/lib/opencloud-process.fixture.mjs" })
		local expire: (() -> ())? = nil
		local seen = ""
		-- Preserve real process, status and streams; observe bytes without replacing IO.
		local observed = {
			stdin = child.stdin,
			stderr = child.stderr,
			stdout = {
				read = function(_self: any, count: number)
					local chunk = child.stdout:read(count)
					if chunk then
						seen ..= chunk
						if string.find(seen, "READY\n", 1, true) then
							local trigger = expire
							expire = nil
							if trigger then
								trigger()
							end
						end
					end
					return chunk
				end,
			},
			kill = function(_self: any)
				child:kill()
			end,
			status = function(_self: any)
				return child:status()
			end,
		}
		local state = lifecycle.exchange(observed, "fixture input", function(trigger)
			expire = trigger
			return Deadline.arm(5, trigger)
		end)
		assert(string.find(seen, "READY\n", 1, true), "deadline must follow barrier, not timing luck")
		assert(
			state.expired and state.killAttempted and state.status ~= nil,
			"state.expired and state.killAttempted and state.status ~= nil"
		)
		assert(
			state.cleaned and not state.residual and state.stdoutEOF and state.stderrEOF,
			"state.cleaned and not state.residual and state.stdoutEOF and state.stderrEOF"
		)
	end,
}
