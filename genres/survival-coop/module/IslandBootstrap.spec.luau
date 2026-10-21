--!strict
local Bootstrap = require("./IslandBootstrap")
local function fake()
	local calls = {}
	local facts: any = {
		level = 60,
		homeAccessCode = "home-code",
		expedition = {
			index = 1,
			level = 30,
			developmentGrade = 2,
			stage = 2,
			completedStage = 1,
			completedObjectives = 2,
			expiresAt = 100,
		},
	}
	local env: any = {
		roles = { harbor = 1, home = 2, archipelago = 3, frontier60 = 4 },
		placeId = 1,
		privateServerId = "",
		isStudio = false,
		players = {},
		facts = function()
			return facts
		end,
		now = function()
			return 10
		end,
		prepareHandoff = function()
			table.insert(calls, "drain")
			return { ok = true }
		end,
		resumeHandoff = function()
			table.insert(calls, "resume")
			return { ok = true }
		end,
		completeHandoff = function()
			return { ok = true }
		end,
		newTeleportOptions = function()
			return {}
		end,
		teleportService = {
			TeleportAsync = function()
				table.insert(calls, "teleport")
			end,
		},
	}
	return env, calls, facts
end
return {
	["production expedition admission uses the committed document gate before handoff"] = function()
		local env, calls = fake()
		env.admitExpedition = function(actor)
			assert(actor == "1", "server actor identity passed")
			return false, "expiry_imminent"
		end
		local ok, reason = Bootstrap.start(env).travel({ UserId = 1 }, "archipelago")
		assert(not ok and reason == "expiry_imminent" and #calls == 0, "document gate precedes handoff")
		env.admitExpedition = function()
			return true
		end
		assert(Bootstrap.start(env).travel({ UserId = 1 }, "archipelago"), "committed document authorizes travel")
		assert(table.concat(calls, ",") == "drain,teleport", "drain precedes teleport after admission")
	end,
	["unknown live place and zero fail closed"] = function()
		local env = fake()
		env.placeId = 0
		assert(not pcall(Bootstrap.start, env), "IslandBootstrap.spec.luau: routing invariant")
		env.placeId = 99
		assert(not pcall(Bootstrap.start, env), "IslandBootstrap.spec.luau: routing invariant")
		env.roles.invalid = 99
		assert(not pcall(Bootstrap.start, env), "IslandBootstrap.spec.luau: routing invariant")
	end,
	["Studio is explicitly labeled and requires a role"] = function()
		local env = fake()
		env.isStudio = true
		assert(not pcall(Bootstrap.start, env), "IslandBootstrap.spec.luau: routing invariant")
		env.studioRole = "onboarding"
		assert(Bootstrap.start(env).mode == "studio-single", "IslandBootstrap.spec.luau: routing invariant")
	end,
	["routing only home entry owns no gameplay session"] = function()
		local env = fake()
		env.placeId = 2
		assert(Bootstrap.start(env).gameplay == false, "IslandBootstrap.spec.luau: routing invariant")
		env.privateServerId = "reserved"
		assert(Bootstrap.start(env).gameplay == true, "IslandBootstrap.spec.luau: routing invariant")
	end,
	["forbidden and level gated travel never drains"] = function()
		local env, calls, facts = fake()
		facts.level = 59
		local ok, reason = Bootstrap.start(env).travel({ UserId = 1 }, "frontier60")
		assert(not ok and reason == "level_gate" and #calls == 0, "IslandBootstrap.spec.luau: routing invariant")
		env.placeId = 2
		local forbidden, forbiddenReason = Bootstrap.start(env).travel({ UserId = 1 }, "frontier60")
		assert(
			not forbidden and forbiddenReason == "transition_not_allowed" and #calls == 0,
			"forbidden travel cannot drain"
		)
	end,
	["mission gate and drain precede teleport and failure resumes"] = function()
		local env, calls, facts = fake()
		facts.expedition.completedObjectives = 1
		local ok, reason = Bootstrap.start(env).travel({ UserId = 1 }, "archipelago")
		assert(not ok and reason == "mission_gate" and #calls == 0, "IslandBootstrap.spec.luau: routing invariant")
		facts.expedition.completedObjectives = 2
		assert(
			Bootstrap.start(env).travel({ UserId = 1 }, "archipelago"),
			"IslandBootstrap.spec.luau: routing invariant"
		)
		assert(table.concat(calls, ",") == "drain,teleport", "IslandBootstrap.spec.luau: routing invariant")
		env.teleportService.TeleportAsync = function()
			error("failed")
		end
		local failed, failureReason = Bootstrap.start(env).travel({ UserId = 1 }, "archipelago")
		assert(
			not failed and failureReason == "teleport_failed" and calls[#calls] == "resume",
			"failed teleport restores source"
		)
	end,
}
