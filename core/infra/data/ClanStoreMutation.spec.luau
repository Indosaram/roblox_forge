--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Data = require("../../domain/genre/SerializedData")
local Fenced = require("./FencedStore")
local Clan = require("../../domain/settlement/Clan")
return {
	["negative fixtures kill membership cap and uniqueness guard mutations"] = function()
		local source = fs.readFile("core/infra/data/ClanStore.luau")
		for _, case in
			{
				{ guard = 'assert(members[actor] == nil, "ALREADY_IN_CLAN")', kind = "duplicate" },
				{ guard = 'assert(count <= config.rules.maxMembers, "CLAN_FULL")', kind = "cap" },
			}
		do
			local first, last = string.find(source, case.guard, 1, true)
			assert(first and last, "mutation anchor exists")
			local mutated = string.sub(source, 1, first - 1) .. "-- guard removed" .. string.sub(source, last + 1)
			local module = luau.load(mutated, {
				environment = {
					require = function(path: string): any
						return if string.find(path, "SerializedData", 1, true) then Data else Fenced
					end,
				},
			})()
			local persisted: any = nil
			local service = {}
			function service:UpdateAsync(_key: string, transform: any): any
				persisted = transform(Data.clone(persisted))
				return Data.clone(persisted)
			end
			local directory = module.new({
				dataStore = service,
				rules = { maxMembers = 1 },
				maxBytes = 1000,
				encode = function(): string
					return "{}"
				end,
				fence = {
					sessionId = "s",
					leaseSeconds = 10,
					now = function(): number
						return 0
					end,
				},
			})
			local token = assert(
				directory.store:acquire("clan:a", function(): any
					return Clan.new("a", "owner")
				end),
				"seed mutation directory"
			)
			local invalid
			if case.kind == "duplicate" then
				invalid = directory.store:acquire("clan:b", function(): any
					return Clan.new("b", "owner")
				end)
			else
				invalid = directory.store:update(token, function(data: any): any
					data.members.other = { role = "member", withdraw = false }
					return data
				end)
			end
			assert(invalid ~= nil, "removed guard admits invalid state; normal negative fixture kills mutant")
		end
	end,
}
