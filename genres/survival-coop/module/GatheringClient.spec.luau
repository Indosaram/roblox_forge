--!strict
local GatheringClient = require("./GatheringClient")

return {
	["gather label follows the locale prefix and defaults to English"] = function()
		assert(GatheringClient.actionText("ko-kr") == "채집하기", "korean")
		assert(GatheringClient.actionText("en-us") == "Gather", "english")
		assert(GatheringClient.actionText(nil) == "Gather", "no locale")
	end,
	["a gather still pending is labelled as collecting, not as a fresh gather"] = function()
		assert(GatheringClient.actionText("ko-kr", true) == "채집 중...", "ko busy")
		assert(GatheringClient.actionText("en-us", true) == "Collecting...", "en busy")
		assert(GatheringClient.actionText("en-us", false) == "Gather", "idle")
	end,
	["refused gathers explain the reason in the player's locale"] = function()
		local refused = function(reason: string, requirement: any?)
			return { ok = false, reason = reason, data = { status = "rejected", requirement = requirement } }
		end
		assert(
			GatheringClient.refusalText("en-us", refused("LEVEL_LOCKED", { level = 30 })) == "Requires level 30",
			"en level"
		)
		assert(
			GatheringClient.refusalText("ko-kr", refused("LEVEL_LOCKED", { level = 30 })) == "레벨 30 필요",
			"ko level"
		)
		local names = { ["starter-axe"] = "Starter Axe" }
		local tool = GatheringClient.refusalText("en-us", refused("TOOL_UNAVAILABLE", { tool = "starter-axe" }), names)
		assert(tool == "Requires Starter Axe (equip it)", tostring(tool))
		assert(GatheringClient.refusalText("en-us", refused("TOOL_UNAVAILABLE")) == "Equip the right tool", "no detail")
		assert(GatheringClient.refusalText("en-us", refused("ODD")) == "Cannot gather (ODD)", "unknown still visible")
		assert(GatheringClient.refusalText("en-us", { ok = true, data = { status = "confirmed" } }) == nil, "success")
	end,
	["a node on cooldown shows the seconds until it can be gathered again"] = function()
		local cooling = {
			ok = false,
			reason = "NODE_DEPLETED",
			data = { status = "rejected", requirement = { retryMillis = 41200 } },
		}
		local ko = GatheringClient.refusalText("ko-kr", cooling)
		assert(ko == "아직 다시 채집할 수 없어요 (42초)", tostring(ko))
		local en = GatheringClient.refusalText("en-us", cooling)
		assert(en == "Not ready to gather again (42s)", tostring(en))
		cooling.data.requirement.retryMillis = 0
		assert(GatheringClient.refusalText("en-us", cooling) == "Not ready to gather again (1s)", "never 0s")
	end,
	["a gather credited but pending finalization is replayed until it settles"] = function()
		-- Studio p36: the first answer is { ok = false, data = { status = "pending" } } (one durable
		-- transfer step); without a replay the prompt stayed '채집 중...' forever.
		local answers: { any } = {
			{ ok = false, data = { status = "pending", objectiveError = "unverified_objective" } },
			{ ok = true, stateVersion = 3, data = { status = "confirmed" } },
		}
		local calls = 0
		local result = GatheringClient.drive(function()
			calls += 1
			return answers[calls]
		end)
		assert(calls == 2 and result.ok == true and result.data.status == "confirmed", "settled, calls=" .. calls)
		local finals: { any } = {
			{ ok = false, reason = "NODE_DEPLETED", data = { status = "rejected" } },
			{ ok = false, reason = "COMMAND_PENDING" },
			{ ok = true, data = { status = "confirmed" } },
		}
		for _, final in finals do
			calls = 0
			GatheringClient.drive(function()
				calls += 1
				return final
			end)
			assert(calls == 1, "settled or refused answers are not replayed")
		end
		calls = 0
		local stuck = GatheringClient.drive(function()
			calls += 1
			return answers[1]
		end)
		assert(calls == 5 and stuck.data.status == "pending", "bounded replays, calls=" .. calls)
	end,
	["the server bridge forwards the cooldown detail to the client result"] = function()
		local Bridge = require("./GatheringBridge")
		local runtime: any = {
			command = function()
				return {
					status = "rejected",
					error = "NODE_DEPLETED",
					transfers = {},
					requirement = { retryMillis = 5000 },
				}
			end,
		}
		local bridge = Bridge.new({
			resolve = function()
				return runtime
			end,
		})
		local result = bridge.command(
			"1",
			{ "tree-1", 3 },
			{ actorId = "1", requestId = "r", sessionEpoch = 0 } :: any,
			10,
			function()
				return { ok = true }
			end
		)
		assert(
			GatheringClient.refusalText("ko-kr", result) == "아직 다시 채집할 수 없어요 (5초)",
			"end to end"
		)
	end,
}
