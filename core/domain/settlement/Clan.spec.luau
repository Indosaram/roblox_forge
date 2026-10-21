--!strict
local Clan = require("./Clan")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()
local function fixture(): (any, any, any)
	local operations = {}
	for _, operation in Content.operations do
		operations[operation.id] = operation
	end
	local ctx: any = {
		rules = { maxMembers = 50, maxLevel = 20, missionExperience = 100, levelExperience = 500, cancelRefund = 0.5 },
		operations = operations,
		hall = true,
		territoryAllowed = true,
		transferAuthorized = true,
	}
	local state = Clan.new("alpha", "owner")
	local serial = 0
	local function command(actor: string, operation: string, args: any?, now: number?): (any?, string?)
		serial += 1
		local updated, reason = Clan.apply(state, actor, operation, args or {}, tostring(serial), now or 0, ctx)
		if updated then
			state = updated
		end
		return updated, reason
	end
	return command, function(): any
		return state
	end, ctx
end
return {
	["clan capacity membership roles and relocation preserve grants"] = function()
		local command, snapshot, ctx = fixture()
		assert(not command("outsider", "withdraw", { amount = 1 }), "clan invariant: 23")
		assert(not command("owner", "leave"), "clan invariant: 24")
		for index = 1, ctx.rules.maxMembers - 1 do
			local actor = "member" .. tostring(index)
			assert(command("owner", "invite", { target = actor }), "clan invariant: 27")
			assert(command(actor, "join"), "clan invariant: 28")
		end
		assert(command("owner", "invite", { target = "overflow" }), "clan invariant: 30")
		local _, reason = command("overflow", "join")
		assert(reason == "CLAN_FULL", "clan invariant: 32")
		assert(not command("member1", "role", { target = "member2", role = "officer" }), "clan invariant: 33")
		assert(command("owner", "role", { target = "member1", role = "officer" }), "clan invariant: 34")
		assert(not command("member1", "capability", { target = "member1", enabled = true }), "clan invariant: 35")
		assert(command("owner", "capability", { target = "member1", enabled = true }), "clan invariant: 36")
		assert(command("owner", "deposit", { amount = 100 }), "clan invariant: 37")
		assert(command("member1", "relocate", { territory = "next" }), "clan invariant: 38")
		assert(snapshot().members.member1.withdraw and snapshot().journal[1].to == "next", "clan invariant: 39")
		assert(command("member1", "withdraw", { amount = 10 }), "clan invariant: 40")
		assert(snapshot().funds == 90, "clan invariant: 41")
		assert(command("member1", "leave"), "clan invariant: 42")
		assert(not command("member1", "withdraw", { amount = 10 }), "clan invariant: 43")
		assert(not command("member1", "research-start", { id = "clan-research-exploration" }), "clan invariant: 44")
		assert(snapshot().funds == 90, "clan invariant: 45")
		assert(command("owner", "transfer", { target = "member2" }), "clan invariant: 46")
		assert(snapshot().owner == "member2" and snapshot().members.owner.role == "officer", "clan invariant: 47")
		assert(command("owner", "leave"), "clan invariant: 48")
		assert(not command("member2", "dissolve"), "clan invariant: 49")
	end,
	["clan revision conflicts revoke withdrawal before concurrent spend"] = function()
		local command, snapshot = fixture()
		assert(command("owner", "invite", { target = "helper" }), "clan invariant: 53")
		assert(command("helper", "join"), "clan invariant: 54")
		assert(command("owner", "capability", { target = "helper", enabled = true }), "clan invariant: 55")
		assert(command("owner", "deposit", { amount = 50 }), "clan invariant: 56")
		local revision = snapshot().revision
		assert(command("owner", "role", { target = "helper", role = "visitor" }), "clan invariant: 58")
		assert(not Clan.allowed(snapshot(), "helper", "withdraw"), "clan invariant: 59")
		assert(not command("helper", "withdraw", { amount = 10, expectedRevision = revision }), "clan invariant: 60")
		assert(not command("helper", "withdraw", { amount = 10 }), "clan invariant: 61")
		assert(not command("helper", "deposit", { amount = 10 }), "clan invariant: 62")
		assert(not command("helper", "relocate", { territory = "stolen" }), "clan invariant: 63")
		assert(not command("owner", "role", { target = "helper", role = "owner" }), "clan invariant: 64")
		assert(not command("owner", "transfer", { target = "helper" }), "clan invariant: 65")
		assert(snapshot().funds == 50, "clan invariant: 66")
	end,
	["clan shared timed research gates capture only at capture time"] = function()
		local command, snapshot, ctx = fixture()
		local id = "clan-research-advanced-capture"
		local definition = ctx.operations[id]
		assert(command("owner", "invite", { target = "helper" }), "clan invariant: 72")
		assert(command("helper", "join"), "clan invariant: 73")
		assert(not command("helper", "research-start", { id = id }), "clan invariant: 74")
		assert(not command("owner", "research-start", { id = id }), "clan invariant: 75")
		local index = 0
		while snapshot().level < definition.gates.clanLevel do
			index += 1
			ctx.contribution = "mission:" .. tostring(index)
			assert(command("helper", "contribute"), "clan invariant: 80")
		end
		assert(not command("helper", "contribute"), "clan invariant: 82")
		assert(command("owner", "deposit", { amount = definition.cost * 2 }), "clan invariant: 83")
		ctx.hall = false
		assert(not command("owner", "research-start", { id = id }), "clan invariant: 85")
		ctx.hall = true
		assert(command("owner", "research-start", { id = id }, 10), "clan invariant: 87")
		local jobId = next(snapshot().jobs)
		assert(not command("owner", "research-start", { id = id }, 11), "clan invariant: 89")
		assert(not command("owner", "research-complete", { jobId = jobId }, 11), "clan invariant: 90")
		assert(
			not Clan.effect(snapshot(), "helper", "advanced-capture", 11, { owner = "alpha", expiresAt = 9999 }),
			"clan invariant: 91"
		)
		assert(command("owner", "research-complete", { jobId = jobId }, 10 + definition.seconds), "clan invariant: 92")
		assert(
			not command("owner", "research-cancel", { jobId = jobId }, 10 + definition.seconds),
			"clan invariant: 93"
		)
		assert(
			Clan.effect(snapshot(), "helper", "advanced-capture", 2000, { owner = "alpha", expiresAt = 3000 }),
			"clan invariant: 94"
		)
		assert(
			not Clan.effect(snapshot(), "helper", "advanced-capture", 3000, { owner = "alpha", expiresAt = 3000 }),
			"clan invariant: 95"
		)
		assert(
			not Clan.effect(snapshot(), "helper", "advanced-capture", 2000, { owner = "beta", expiresAt = 3000 }),
			"clan invariant: 96"
		)
		assert(command("helper", "leave"), "clan invariant: 97")
		assert(
			not Clan.effect(snapshot(), "helper", "advanced-capture", 2000, { owner = "alpha", expiresAt = 3000 }),
			"clan invariant: 98"
		)
	end,
	["clan cancellation replay and invalid transfers conserve funds"] = function()
		local command, snapshot, ctx = fixture()
		local state = snapshot()
		state.level = 20
		local definition = ctx.operations["clan-research-exploration"]
		assert(command("owner", "deposit", { amount = definition.cost }), "clan invariant: 105")
		assert(command("owner", "research-start", { id = definition.id }, 10), "clan invariant: 106")
		local jobId = next(snapshot().jobs)
		assert(command("owner", "research-cancel", { jobId = jobId }, 11), "clan invariant: 108")
		assert(snapshot().funds == math.floor(definition.cost / 2), "clan invariant: 109")
		assert(not command("owner", "research-cancel", { jobId = jobId }, 12), "clan invariant: 110")
		assert(not command("owner", "research-complete", { jobId = jobId }, 10000), "clan invariant: 111")
		assert(not command("owner", "withdraw", { amount = 1 }), "clan invariant: 112")
		assert(command("owner", "capability", { target = "owner", enabled = true }), "clan invariant: 113")
		assert(not command("owner", "withdraw", { amount = definition.cost }), "clan invariant: 114")
		assert(not command("owner", "deposit", { amount = -1 }), "clan invariant: 115")
		ctx.transferAuthorized = false
		assert(not command("owner", "deposit", { amount = 5 }), "clan invariant: 117")
		ctx.transferAuthorized = true
		local before = snapshot()
		local once =
			assert(Clan.apply(before, "owner", "deposit", { amount = 2 }, "same", 12, ctx), "clan invariant: 120")
		local twice =
			assert(Clan.apply(once, "owner", "deposit", { amount = 2 }, "same", 12, ctx), "clan invariant: 121")
		assert(twice.funds == once.funds, "clan invariant: 122")
	end,
}
