--!strict
local Extension = require("./ArchipelagoExtension")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local World = require("../../../games/robango-island/src/server/ArchipelagoWorld")
local serde = require("@lune/serde")
return {
	["opaque mission IDs and fenced transactions protect the owned bag"] = function()
		local document: any = { bag = { { id = "owned-pick", durability = 27 } } }
		local now, returns, fenced = 0, 0, false
		local extension = Extension.new({
			content = Content,
			entryBuffer = 30,
			now = function()
				return now
			end,
			facts = function()
				return { level = 60, developmentRank = 10, instabilityAccess = 5 }
			end,
			verify = function()
				return nil
			end,
			store = {
				transaction = function(_actor, transform)
					if fenced then
						return { ok = false, reason = "lease_lost" }
					end
					return transform(document)
				end,
			},
			returnHome = function()
				returns += 1
				return { ok = true }
			end,
		})
		assert(
			extension.open(
				"owner",
				{ id = "trip", index = 1, seed = 74, ttl = 1000, revision = "v2", entryBuffer = 30 }
			).ok,
			"archipelago invariant"
		)
		assert(extension.objective("owner", "fake").reason == "unverified_objective", "archipelago invariant")
		assert(extension.nextIsland("owner").reason == "mission_gate", "archipelago invariant")
		fenced = true
		assert(extension.recover("owner", "abandon").reason == "lease_lost" and returns == 0, "archipelago invariant")
		fenced = false
		now = 1000
		assert(extension.recover("owner", "reconnect").ok and returns == 1, "archipelago invariant")
		assert(document.bag[1].id == "owned-pick" and document.bag[1].durability == 27, "archipelago invariant")
	end,
	["all layouts emit deterministic differing terrain and every catalog entity"] = function()
		local signatures = {}
		for _, layout in Content.layouts :: any do
			if not string.match(layout.id, "^rw%.a%d%.s%d$") then
				continue
			end
			local a = World.describe(Content, layout.id, 74)
			local b = World.describe(Content, layout.id, 74)
			assert(serde.encode("json", a) == serde.encode("json", b), "archipelago invariant")
			local otherSeed = World.describe(Content, layout.id, 75)
			assert(
				serde.encode("json", a.columns) ~= serde.encode("json", otherSeed.columns),
				"seed changes terrain outside protected navigation"
			)
			local geometry = {}
			for _, ribbon in a.terrain do
				table.insert(geometry, { ribbon.from, ribbon.to, ribbon.width, ribbon.biome })
			end
			local signature = serde.encode("json", geometry)
			assert(not signatures[signature], "distinct module terrain")
			signatures[signature] = true
			local counts = { terrain = 0, resource = 0, wildlife = 0, objective = 0, dock = 0 }
			local env: any = {
				content = Content,
				layoutId = layout.id,
				seed = 74,
				begin = function()
					return {}
				end,
			}
			for name in counts do
				env[name] = function()
					counts[name] += 1
				end
			end
			env.hazard = function() end
			env.refuge = function() end
			env.column = function() end
			World.build(env)
			assert(counts.terrain == #a.terrain and counts.resource == #layout.resourceNodes, "archipelago invariant")
			assert(
				counts.wildlife == #layout.spawns and counts.objective == 2 and counts.dock == 2,
				"archipelago invariant"
			)
		end
	end,
}
