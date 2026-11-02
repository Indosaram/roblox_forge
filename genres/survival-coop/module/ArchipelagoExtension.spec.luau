--!strict
local Extension = require("./ArchipelagoExtension")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local World = require("../../../games/robango-island/src/server/ArchipelagoWorld")
local serde = require("@lune/serde")
return {
	["fxB: an expired trip never entered is settled on the next open instead of blocking it"] = function()
		-- journey6h @13.5m: open -> expedition_active forever ashore once the trip window ended.
		local document: any = {}
		local now = 10
		local extension = Extension.new({
			content = Content,
			entryBuffer = 30,
			now = function()
				return now
			end,
			facts = function()
				return { level = 60, developmentRank = 10, instabilityAccess = 5 }
			end,
			store = {
				transaction = function(_actor, transform)
					local candidate = serde.decode("json", serde.encode("json", document))
					local result = transform(candidate)
					if result.ok then
						document = candidate
					end
					return result
				end,
				snapshot = function()
					return document
				end,
			},
		})
		local function open(id: string): any
			return extension.open("a", { id = id, index = 1, seed = 7, ttl = 1000, revision = "v", entryBuffer = 30 })
		end
		assert(open("first").ok, "first trip opens")
		now = 500
		assert(open("busy").reason == "expedition_active", "a live trip still blocks")
		now = 1000
		local second = open("second")
		assert(second.ok, "the expired trip is settled and the next opens: " .. tostring(second.reason))
		assert(document.archipelago.id == "second" and document.archipelago.status == "active", "new trip")
	end,
	["a member on a shared route opens it with the owner's route access but their own level gate"] = function()
		local documents: any = { owner = { routeShare = { route = 2, members = { b = "member", c = "invited" } } } }
		local extension = Extension.new({
			content = Content,
			entryBuffer = 30,
			now = function()
				return 10
			end,
			facts = function(actor)
				return { level = if actor == "low" then 1 else 60, developmentRank = 10, instabilityAccess = 1 }
			end,
			store = {
				transaction = function(actor, transform)
					local candidate = serde.decode("json", serde.encode("json", documents[actor] or {}))
					local result = transform(candidate)
					if result.ok then
						documents[actor] = candidate
					end
					return result
				end,
				snapshot = function(actor)
					return documents[actor]
				end,
			},
		})
		local function open(actor: string, id: string): any
			return extension.open(
				actor,
				{ id = id, index = 2, seed = 74, ttl = 1000, revision = "v2", entryBuffer = 30, sharedBy = "owner" }
			)
		end
		assert(open("b", "trip-b").ok, "a shared member opens route 2")
		assert(open("c", "trip-c").reason == "instability_gate", "an invite alone lends nothing")
		documents.owner.routeShare.members.low = "member"
		assert(open("low", "trip-low").reason == "level_gate", "the member's own level gate holds")
	end,
	["mission development awards once and a completed route unlocks the next instability"] = function()
		local document: any = {}
		local receipt: any = nil
		local extension = Extension.new({
			content = Content,
			entryBuffer = 30,
			now = function()
				return 10
			end,
			facts = function()
				return { level = 60, developmentRank = 10, instabilityAccess = 5 }
			end,
			verify = function()
				return receipt
			end,
			store = {
				transaction = function(_actor, transform)
					local candidate = serde.decode("json", serde.encode("json", document))
					local result = transform(candidate)
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
		local sequence = 0
		for stageNumber = 1, 4 do
			local layoutId = "rw.a1.s" .. tostring(stageNumber)
			for _, stage in Content.stages :: any do
				if stage.layout == layoutId then
					for _, objective in stage.objectives do
						sequence += 1
						receipt = {
							id = "verified:" .. tostring(sequence),
							actor = "owner",
							expedition = "trip",
							revision = "v2",
							objective = objective.id,
							action = objective.action,
							target = objective.target,
							quantity = objective.quantity,
						}
						assert(extension.objective("owner", receipt.id).ok, "verified objective settles")
						local points = document.development.points
						assert(
							extension.objective("owner", receipt.id).reason == "duplicate_receipt",
							"objective replay refused"
						)
						assert(document.development.points == points, "objective replay cannot award development")
					end
				end
			end
			assert(extension.nextIsland("owner").ok, "completed island advances")
		end
		local expected = 0
		for _, mission in Content.missions :: any do
			if document.development.definitions[mission.id] then
				expected += mission.rewards.development or 0
			end
		end
		assert(expected > 0 and document.development.points == expected, "only completed mission definitions award")
		assert(
			document.development.instabilityAccess == 2 and document.archipelago.status == "complete",
			"route completion unlocks index two"
		)
	end,
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
