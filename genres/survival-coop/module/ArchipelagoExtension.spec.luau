--!strict
local Extension = require("./ArchipelagoExtension")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local World = require("../../../games/robango-island/src/server/ArchipelagoWorld")
local serde = require("@lune/serde")
return {
	["gather objectives consume only current route finalized node receipts once"] = function()
		local document: any = {}
		local grant: any = nil
		local commit = true
		local extension = Extension.new({
			content = Content,
			entryBuffer = 30,
			now = function()
				return 10
			end,
			facts = function()
				return { level = 60, developmentRank = 10, instabilityAccess = 5 }
			end,
			gatherReceipt = function(actor, epoch, requestId)
				assert(actor == "owner" and epoch == 1 and requestId == "g1", "exact server receipt identity")
				return grant
			end,
			store = {
				transaction = function(_actor, transform)
					local candidate = serde.decode("json", serde.encode("json", document))
					local result = transform(candidate)
					if result.ok and not commit then
						return { ok = false, reason = "commit_failed" }
					end
					if result.ok then
						document = candidate
					end
					return result
				end,
			},
		})
		assert(
			extension.open(
				"owner",
				{ id = "trip", index = 1, seed = 74, ttl = 1000, revision = "v2", entryBuffer = 30 }
			).ok,
			"route opened"
		)
		assert(
			extension.gatherObjective("owner", 1, "g1").reason == "unverified_objective",
			"uncommitted receipt refused"
		)
		grant = { nodeId = "rw.a1.s1.material.wood", items = { wood = 5, stone = 30 }, createdAt = 9 }
		assert(
			extension.gatherObjective("owner", 1, "g1").reason == "unverified_objective",
			"pre-route receipt refused"
		)
		grant.createdAt = 10
		grant.items = { stone = 5 }
		assert(
			extension.gatherObjective("owner", 1, "g1").reason == "invalid_quantity",
			"unrelated mint output cannot satisfy wood objective"
		)
		grant.items = { wood = 5, stone = 30 }
		commit = false
		assert(
			extension.gatherObjective("owner", 1, "g1").reason == "commit_failed",
			"objective requires durable acknowledgement"
		)
		assert(
			not document.archipelago.completed["rw.a1.s1.gather"] and not document.gatherReceipts,
			"failed commit consumes no objective receipt"
		)
		commit = true
		assert(extension.gatherObjective("owner", 1, "g1").ok, "finalized current-layout gather credited")
		assert(document.archipelago.completed["rw.a1.s1.gather"], "authored objective completed")
		assert(extension.gatherObjective("owner", 1, "g1").reason == "duplicate_receipt", "receipt cannot grant twice")
		document.archipelago = nil
		assert(
			extension.open(
				"owner",
				{ id = "trip2", index = 1, seed = 74, ttl = 1000, revision = "v2", entryBuffer = 30 }
			).ok,
			"new route opened"
		)
		assert(
			extension.gatherObjective("owner", 1, "g1").reason == "duplicate_receipt",
			"new route cannot recycle consumed receipt"
		)
	end,
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
