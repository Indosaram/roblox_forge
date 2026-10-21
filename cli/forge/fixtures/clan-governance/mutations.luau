--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Data = require("../../../../core/domain/genre/SerializedData")
local mutations = {
	{ "Clan", "departed-membership", 'return nil, "NOT_MEMBER"', "return state, nil" },
	{ "Clan", "membership-limit", "if count >= ctx.rules.maxMembers then", "if false then" },
	{ "Clan", "role-assignment", 'if not M.allowed(state, actor, "govern") then', "if false then" },
	{
		"Clan",
		"withdraw-revocation",
		"out.members[args.target].withdraw = false",
		"out.members[args.target].withdraw = true",
	},
	{ "Clan", "research-clock", "if now < job.finishAt then", "if false then" },
	{ "Clan", "research-cancel-once", 'if not job or job.status ~= "pending" then', "if not job then" },
	{ "Clan", "capture-expiry", "now < outpost.expiresAt", "true" },
	{ "Clan", "capture-ownership", "outpost.owner == state.clanId", "true" },
	{ "Clan", "cancel-refund", "math.floor(job.cost * ctx.rules.cancelRefund)", "job.cost" },
	{ "ClanOutpost", "personal-home-raid", 'if ctx.role ~= "team-outpost" then', "if false then" },
	{ "ClanOutpost", "opt-in", "not ctx.optedIn(player)", "false" },
	{ "ClanOutpost", "minimum-team", "#team.actors < ctx.rules.minTeam", "false" },
	{ "ClanOutpost", "contested-control", "if count == 1 then", "if count > 0 then" },
	{ "ClanOutpost", "duplicate-settlement", 'match.status ~= "active"', "false" },
	{ "ClanOutpost", "departed-occupant", "ctx.eligible(player, clanId)", "true" },
}
for _, mutation in mutations do
	local path = "core/domain/settlement/" .. mutation[1]
	local original = fs.readFile(path .. ".luau")
	local start, finish = string.find(original, mutation[3], 1, true)
	assert(start and finish, "missing mutation: " .. mutation[2])
	local source = string.sub(original, 1, start - 1) .. mutation[4] .. string.sub(original, finish + 1)
	local mutant = luau.load(source, { environment = {
		require = function(): any
			return Data
		end,
	} })()
	local tests = luau.load(fs.readFile(path .. ".spec.luau"), {
		environment = {
			require = function(name: string): any
				if name == "./" .. mutation[1] then
					return mutant
				end
				if name == "@lune/fs" then
					return fs
				end
				assert(name == "@lune/luau", "unknown mutation import")
				return luau
			end,
		},
	})()
	local killed = false
	for _, test in tests do
		if not pcall(test) then
			killed = true
		end
	end
	assert(killed, "mutation survived: " .. mutation[2])
	print("KILLED " .. mutation[2])
end
