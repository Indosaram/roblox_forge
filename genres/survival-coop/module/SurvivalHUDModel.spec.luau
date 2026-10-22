--!strict
local Model = require("./SurvivalHUDModel")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Content = require("../../../core/domain/survival/Content")
local Job = require("../../../core/domain/crafting/Job")
local Workshop = require("./Workshop")
local Settlement = require("../../../core/domain/settlement/Settlement")
local serde = require("@lune/serde")
local function status(state: any): string
	return state.status
end

local function model(): any
	local count = 0
	local state = Model.new("alice", function()
		count += 1
		return "request-" .. count
	end)
	local actions = {}
	for _, verb in
		{
			"craft-reserve",
			"craft-start",
			"craft-complete",
			"craft-cancel",
			"transfer-deposit",
			"transfer-withdraw",
			"settlement-reserve",
			"settlement-place",
			"rest",
			"food",
		}
	do
		table.insert(actions, "survival-coop:" .. verb)
	end
	state.receive({ durable = { actions = actions, sessionEpoch = 4 } })
	return state
end

return {
	["repair button shows Job.repairCost only for damaged gear and sends item-repair"] = function()
		local content: any = {
			operations = { { kind = "repair", cost = 10 } },
			items = {
				{ id = "axe-t3", maxDurabilityMilli = 100000 } :: any,
				{ id = "wood" },
			},
		}
		local item = { catalogId = "axe-t3", qualityMilli = 1000, durabilityMilli = 100000 }
		assert(Model.repairCost(item, content) == nil, "full durability hides repair")
		item.durabilityMilli = 5
		assert(Model.repairCost(item, content) == 30, "tier 3 costs 30")
		assert(
			Model.repairCost({ catalogId = "wood", qualityMilli = 1000, durabilityMilli = 0 }, content) == nil,
			"raw"
		)
		assert(Model.repairCost(item, { items = content.items }) == nil, "no repair operation")
		local tagged: any = {
			operations = { { kind = "repair", cost = 10, eligibleTags = { "weapon-tool" } } },
			items = { { id = "axe-t3", maxDurabilityMilli = 100000, tags = {} } },
		}
		assert(Model.repairCost(item, tagged) == nil, "ineligible item hides repair")
		tagged.items[1].tags = { "weapon-tool" }
		assert(Model.repairCost(item, tagged) == 30, "eligible item shows repair")
		local source = require("@lune/fs").readFile("genres/survival-coop/module/SurvivalHUD.luau")
		local anchor = 'mutation("Repair-" .. item.itemId, string.format(t("repair"), cost), "item-repair", function()'
		assert(string.find(source, anchor, 1, true), "bag detail renders the repair button")
		assert(string.find(source, 'command("item-repair", { item.itemId })', 1, true), "button sends item-repair")
	end,
	["placement controls clear equipped tool hotbar at every viewport height"] = function()
		for _, height in { 320, 632, 640, 1080 } do
			local top = height - Model.PLACEMENT_BOTTOM
			local bottom = top + 48
			assert(top >= 0, "placement stays on the viewport")
			assert(bottom < height - 70, "CoreGui tool slots must not intercept placement clicks")
			assert(Model.overPlacementBar(164, top + 24, { X = 0, Y = top }, { X = 328, Y = 48 }))
		end
	end,
	["recipe availability distinguishes station reach from carried materials"] = function()
		local bag = {
			items = {
				branch = { itemId = "branch", catalogId = "branch", quantity = 3 },
				stone = { itemId = "stone", catalogId = "stone", quantity = 3 },
			},
			reservations = {},
		}
		local recipes = {
			{
				id = "starter-axe",
				station = "workbench",
				inputs = {
					{ item = "branch", quantity = 3 },
					{ item = "stone", quantity = 2 },
				},
			},
		}
		local away = Model.recipeOrder(bag, recipes, function()
			return false
		end)[1]
		assert(not away.ready and not away.stationReady, "station reach is missing, not materials")
		assert(#Model.missingMaterials(bag, recipes[1].inputs) == 0, "carried supplies are sufficient")
		local nearby = Model.recipeOrder(bag, recipes, function()
			return true
		end)[1]
		assert(nearby.ready and nearby.stationReady, "same supplies become ready at workbench")
	end,
	["placement action bar retains target through padded pointer bounds"] = function()
		local p, s = { X = 16, Y = 540 }, { X = 328, Y = 48 }
		for _, point in { { 20, 550 }, { 170, 560 }, { 340, 580 }, { 8, 535 } } do
			assert(Model.overPlacementBar(point[1], point[2], p, s), "action bar must lock target")
		end
		assert(not Model.overPlacementBar(170, 510, p, s), "world pointer updates target")
		assert(not Model.overPlacementBar(400, 560, p, s), "beside bar updates target")
	end,
	["reserve feedback reports missing available quantities for bag and warehouse"] = function()
		local bag = {
			items = { wood = { itemId = "wood", catalogId = "wood", quantity = 4 } },
			reservations = { held = { wood = 1 } },
		}
		local missing =
			Model.missingMaterials(bag, { { item = "wood", quantity = 4 }, { item = "flint", quantity = 2 } })
		assert(#missing == 2 and missing[1].available == 3 and missing[1].needed == 4, "reserved stock excluded")
		assert(
			missing[2].id == "flint" and missing[2].available == 0 and missing[2].needed == 2,
			"absent stock reported"
		)
		assert(#Model.missingMaterials(bag, { { item = "wood", quantity = 3 } }) == 0, "enough stock accepted")
	end,
	["pointer placement maps world ground to bounded settlement cells"] = function()
		local config = { width = 8, depth = 6, cellStuds = 4 }
		local x, z = Model.pointerCell(-7, 29, -16, 20, config)
		assert(x == 2 and z == 2, "ground hit maps relative to settlement origin")
		x, z = Model.pointerCell(-100, 100, -16, 20, config)
		assert(x == 0 and z == 5, "pointer remains in settlement bounds")
	end,
	["recipes group by station with available materials first and reservations excluded"] = function()
		local bag = {
			items = { wood = { itemId = "wood", catalogId = "wood", quantity = 3, tags = {}, durabilityMilli = 1000 } },
			reservations = { held = { wood = 1 } },
		}
		local recipes: { any } = {
			{ id = "a-missing", inputs = { { item = "wood", quantity = 3 } }, station = nil },
			{ id = "z-ready", inputs = { { item = "wood", quantity = 2 } }, station = nil },
			{ id = "c-fire", inputs = {}, station = "campfire" },
		}
		local rows = Model.recipeOrder(bag, recipes, function()
			return false
		end)
		assert(rows[1].recipe.id == "z-ready" and rows[1].ready, "craftable hand recipe first")
		assert(rows[2].recipe.id == "a-missing" and not rows[2].ready, "reserved materials cannot craft")
		assert(rows[3].station == "campfire" and not rows[3].ready, "unreachable station cannot craft")
	end,
	["Studio station coordinates aim above embedded station geometry"] = function()
		local target = Model.stationTarget({ x = -32, y = 2, z = -4 }, { x = 4, y = 2, z = 3 })
		local player = { x = -32.08, y = 7.83, z = -8.45 }
		local distance = math.sqrt((target.x - player.x) ^ 2 + (target.y - player.y) ^ 2 + (target.z - player.z) ^ 2)
		assert(target.y == 5 and distance < 6, "workbench interaction ray stays above terrain")
		player = { x = -46.779, y = 7.130, z = -8.345 }
		target = Model.stationTarget({ x = -48, y = 2, z = -4 }, { x = 4, y = 2, z = 3 })
		distance = math.sqrt((target.x - player.x) ^ 2 + (target.y - player.y) ^ 2 + (target.z - player.z) ^ 2)
		assert(distance < 6, "campfire interaction ray stays above terrain")
	end,
	["gather guidance skips unreachable nodes before choosing nearest"] = function()
		local far = { distance = 8, available = true, reachable = true }
		assert(
			Model.nearestGatherable({ { distance = 1, available = true, reachable = false }, far }) == far,
			"blocked nearby resource cannot displace reachable guidance"
		)
	end,
	["a handshake refusal clears once the server's policy arrives (rejoin swaps the server)"] = function()
		local state: any = Model.new("bob", function()
			return "r"
		end)
		-- No policy yet: an action is refused with the handshake banner.
		assert(state.begin("rest", {}) == nil and state.reason == "HANDSHAKE_FAILED", "refused before policy")
		state.receive({ durable = { actions = { "survival-coop:rest" }, sessionEpoch = 1 } })
		assert(state.status ~= "conflict" and state.reason == nil, "policy clears the handshake banner")
		-- Any other refusal is not touched by a policy broadcast.
		state.status, state.reason = "conflict", "BAG_FULL"
		state.receive({ durable = { actions = { "survival-coop:rest" }, sessionEpoch = 1 } })
		local function reason(value: any): string?
			return value.reason
		end
		assert(reason(state) == "BAG_FULL", "unrelated refusal kept")
	end,
	["publication failure exposes recovery without resubmitting committed placement"] = function()
		local state = model()
		local placementArgs: { any } = { "reserved", 1, 2 }
		state.begin("settlement-place", placementArgs)
		state.finish(true, { ok = true, stateVersion = 3, data = { notificationError = "publisher failed" } })
		assert(state.pending == nil and state.retry() == nil, "state.pending == nil and state.retry() == nil")
		assert(
			state.status == "confirmed" and state.reason == "SETTLEMENT_PUBLICATION_FAILED",
			'state.status == "confirmed" and state.reason == "SETTLEMENT_PUBLICATION_FAILED"'
		)
	end,
	["compact sheet fits safe viewport and leaves a scrollable body"] = function()
		for _, viewport in { { 716, 284 }, { 788, 339 }, { 366, 760 }, { 1256, 664 } } do
			local width, height, top = Model.sheetBounds(viewport[1], viewport[2])
			assert(width <= viewport[1] and top >= 0 and top + height <= viewport[2], "sheet within safe area")
			assert(height >= 100, "44 pixel header and touch control fit")
			if viewport[2] < 500 then
				assert(top == 0, "compact sheet starts at safe top")
			else
				-- The HUD's top-right stack ends at STACK_BOTTOM; a sheet starting above it
				-- overlaps the last control and fails the capture geometry contract.
				assert(top >= Model.STACK_BOTTOM, "sheet clears the HUD control stack")
			end
		end
	end,
	["short landscape sheet sits left of the control stack so the tabs stay reachable"] = function()
		for _, viewport in { { 819, 295 }, { 716, 284 }, { 643, 340 } } do
			local stack = math.min(320, math.floor(viewport[1] * 0.45))
			local width, height, top, right = Model.sheetBounds(viewport[1], viewport[2], stack)
			assert(right >= stack, "sheet keeps the stack column free")
			assert(width + right <= viewport[1] and top == 0 and height >= 100, "sheet fits beside the stack")
		end
		local _, _, _, right = Model.sheetBounds(1256, 664, 320)
		assert(right == 0, "tall viewports keep the sheet under the stack")
	end,
	["placement rows retain canonical order and exclude other actors"] = function()
		local first = { actorId = "alice" }
		local second = { actorId = "alice" }
		local settlement: any = { reservations = { z = second, a = first, b = { actorId = "bob" } } }
		local rows = Model.placements(settlement, "alice")
		assert(#rows == 2 and rows[1].id == "a" and rows[2].id == "z", "stable canonical order")
		assert(rows[1].placement == first and rows[2].placement == second, "current placement data")
		settlement.reservations.a = nil
		rows = Model.placements(settlement, "alice")
		assert(#rows == 1 and rows[1].id == "z", "removed placement disappears")
	end,
	["double activation and uncertain response retain one immutable request"] = function()
		local state = model()
		local args = { "cord", "hand" }
		local request = state.begin("craft-reserve", args)
		args[1] = "changed"
		assert(
			request.action == "survival-coop:craft-reserve" and request.args[1] == "cord" and request.args[2] == "hand",
			"reserve tuple remains unchanged"
		)
		assert(
			state.begin("craft-reserve", args) == nil and state.retry() == nil,
			'state.begin("craft-reserve", args) == nil and state.retry() == nil'
		)
		state.finish(false, "network lost")
		assert(
			state.status == "pending" and state.retry() == request,
			'state.status == "pending" and state.retry() == request'
		)
		state.finish(true, { ok = false, reason = "COMMAND_PENDING" })
		assert(state.retry() == request, "state.retry() == request")
		state.finish(true, { ok = true, stateVersion = 9 })
		assert(
			status(state) == "confirmed" and state.pending == nil,
			'state.status == "confirmed" and state.pending == nil'
		)
		assert(
			state.begin("craft-start", { "job-1" }).requestId == "request-2",
			'state.begin("craft-start", { "job-1" }).requestId == "request-2"'
		)
	end,
	["accepted repair without stateVersion settles with a success line, no refusal and no retry"] = function()
		local state = model()
		state.receive({ durable = { actions = { "survival-coop:item-repair" }, sessionEpoch = 4 } })
		state.begin("item-repair", { "axe" })
		-- Personal extension result as returned before the fix (reason leaked on success).
		state.finish(true, { ok = true, reason = "INSUFFICIENT_FUNDS" })
		assert(state.status == "confirmed", "confirmed: " .. tostring(state.status))
		assert(state.reason == nil, "no refusal on success: " .. tostring(state.reason))
		assert(state.pending == nil and state.retry() == nil, "nothing left to retry")
		assert(state.notice == "repaired" and Model.SUCCESS["survival-coop:item-repair"] == "repaired", "success line")
		local Locale = require("./SurvivalHUDLocale")
		assert(Locale.text("ko-kr", "repaired") == "수리 완료", "KO success text")
		state.begin("item-repair", { "axe" })
		assert(state.notice == nil, "a new request clears the previous confirmation")
		state.finish(true, { ok = false, reason = "NOTHING_TO_REPAIR" })
		assert(state.notice == nil and state.reason == "NOTHING_TO_REPAIR", "a later refusal replaces the line")
	end,
	["non-repair acceptance without a persisted outcome keeps its request"] = function()
		local state = model()
		local request = state.begin("craft-reserve", { "cord", "hand" })
		state.finish(true, { ok = true })
		assert(
			state.pending == request and state.retry() == request,
			"only repair has the final personal outcome contract"
		)
	end,
	["committed refusal clears pending while expired epoch requires handshake"] = function()
		local state = model()
		state.begin("craft-complete", { "job-1" })
		state.finish(true, { ok = false, reason = "SLOTS_EXCEEDED", stateVersion = 10 })
		assert(
			state.status == "conflict" and state.pending == nil,
			'state.status == "conflict" and state.pending == nil'
		)
		state.begin("craft-cancel", { "job-1" })
		state.finish(true, { ok = false, reason = "REQUEST_EXPIRED" })
		assert(
			state.durable == nil and state.begin("craft-cancel", { "job-1" }) == nil,
			'state.durable == nil and state.begin("craft-cancel", { "job-1" }) == nil'
		)
	end,
	["transfer phase confirmation and exact tuples"] = function()
		local state = model()
		local args: { any } = { "wood-1", 1 }
		local request: any = state.begin("transfer-deposit", args)
		assert(
			#request.args == 2 and request.args[1] == "wood-1" and request.args[2] == 1,
			'#request.args == 2 and request.args[1] == "wood-1" and request.args[2] == 1'
		)
		state.finish(true, { ok = true, data = { status = "recovering" } })
		assert(
			state.pending == request and state.status == "pending",
			'state.pending == request and state.status == "pending"'
		)
		state.retry()
		state.finish(true, { ok = true, data = { status = "confirmed" } })
		assert(
			state.pending == nil and status(state) == "confirmed",
			'state.pending == nil and state.status == "confirmed"'
		)
		request = state.begin("rest", { "campfire-1" })
		assert(
			request.action == "survival-coop:rest" and #request.args == 1 and request.args[1] == "campfire-1",
			'request.action == "survival-coop:rest" and #request.args == 1 and request.args[1] == "campfire-1"'
		)
	end,
	["server snapshots restore active jobs and reservation availability after rejoin"] = function()
		local content = assert(Content.canonicalize({
			survival_content = 1,
			rules = table.clone(Content.RULES),
			limits = table.clone(Content.DEFAULT_LIMITS),
			items = {
				{ id = "fiber", name = "Fiber", stackMax = 100, weightMilli = 100 },
				{ id = "cord", name = "Cord", stackMax = 100, weightMilli = 100 },
			},
			recipes = {
				{
					id = "cord",
					craftMillis = 1000,
					inputs = { { item = "fiber", quantity = 3 } },
					outputs = { { item = "cord", quantity = 1 } },
				},
			},
		}))
		local bag = Inventory.new("bag", { slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 })
		bag = assert(Inventory.add(bag, Job.catalog(content), {
			itemId = "fiber-1",
			catalogId = "fiber",
			quantity = 6,
			qualityMilli = 1000,
			durabilityMilli = 0,
			attributes = {},
		}, bag.version))
		local context = { actorId = "alice", sessionEpoch = 4, requestId = "reserve-1" }
		local reserved = assert(
			Workshop.reserve(
				Workshop.new("alice"),
				bag,
				context,
				content,
				"v1",
				"cord",
				1000,
				{ carriedContainer = "bag", inReach = true }
			)
		)
		local started =
			assert(Workshop.transition(reserved.jobs, reserved.inventory, context, reserved.jobId, "start", 1000))
		local saved = serde.decode("json", serde.encode("json", Workshop.save(started.jobs)))
		local restored = Workshop.fromSave(saved, "alice", { bag = started.inventory })
		local view: any = Inventory.snapshot(started.inventory)
		view.kind, view.weightMilli = "carried", Inventory.weight(view, Job.catalog(content))
		local state = model()
		state.receive({
			revision = 2,
			snapshots = { ["survival-coop"] = { inventory = { bag = view }, workshop = restored } },
		})
		local rows = Model.items(Model.bag(state.snapshot))
		assert(rows[1].available == 3 and rows[1].reserved == 3, "rows[1].available == 3 and rows[1].reserved == 3")
		assert(
			Model.ingredients(view, content.recipes[1])[1].available == 3,
			"Model.ingredients(view, content.recipes[1])[1].available == 3"
		)
		local jobs = Model.jobs(state.snapshot, "alice")
		assert(
			#jobs == 1 and jobs[1].id == reserved.jobId and jobs[1].job.finishAt == 2000,
			"#jobs == 1 and jobs[1].id == reserved.jobId and jobs[1].job.finishAt == 2000"
		)
		assert(#Model.jobs(state.snapshot, "bob") == 0, '#Model.jobs(state.snapshot, "bob") == 0')
		assert(
			not state.receive({ revision = 1, snapshots = { ["survival-coop"] = {} } }),
			'not state.receive({ revision = 1, snapshots = { ["survival-coop"] = {} } })'
		)
		assert(#Model.jobs(state.snapshot, "alice") == 1, '#Model.jobs(state.snapshot, "alice") == 1')
		local complete = state.begin("craft-complete", { jobs[1].id })
		assert(complete.args[1] == reserved.jobId, "complete.args[1] == reserved.jobId")
		local full = Inventory.snapshot(started.inventory)
		full.limits.slots = 1
		local blocked = assert(Workshop.transition(restored, full, context, complete.args[1], "complete", 2000))
		assert(
			blocked.reason == "FULL_SLOTS" and blocked.jobs.entries[reserved.jobId].job.state == "Ready",
			"full bag retains Ready job"
		)
		local cancelled =
			assert(Workshop.transition(blocked.jobs, blocked.inventory, context, reserved.jobId, "cancel", 2000))
		assert(Inventory.available(cancelled.inventory, "fiber-1") == 6, "cancel releases reserved quantity")
		local committed =
			assert(Workshop.transition(restored, started.inventory, context, complete.args[1], "complete", 2000))
		assert(
			committed.jobs.entries[reserved.jobId].job.state == "Committed",
			'committed.jobs.entries[reserved.jobId].job.state == "Committed"'
		)
	end,
	["placement preview uses native footprint rules and versioned tuple"] = function()
		local settlement =
			Settlement.new({ tribeId = "camp", width = 8, depth = 8, cellStuds = 4, maxMembers = 4 }, "alice")
		local definition = { id = "campfire", footprintX = 2, footprintZ = 1, cost = {} }
		local snapshot = { settlement = settlement, warehouse = { version = 3 } }
		local state = model()
		state.receive({ revision = 1, snapshots = { ["survival-coop"] = {}, survivalSettlement = snapshot } })
		assert(
			state.snapshot.settlement == settlement and state.snapshot.warehouse.version == 3,
			"shared snapshot uses Session envelope"
		)
		local args = assert(Model.buildArgs(snapshot, definition, 2, 2, 1))
		assert(
			#args == 7
				and args[1] == "campfire"
				and args[2] == 2
				and args[3] == 2
				and args[4] == 1
				and args[5] == 0
				and args[6] == 3
				and args[7] == 0,
			"placement tuple carries all authoritative versions"
		)
		local placement = assert(Model.preview(snapshot, "alice", definition, 2, 2, 1))
		assert(
			placement.cells[2].x == 2 and placement.cells[2].z == 3,
			"placement.cells[2].x == 2 and placement.cells[2].z == 3"
		)
		local invalid, reason = Model.preview(snapshot, "alice", definition, 0, 0, 0)
		assert(invalid == nil and reason == "OUT_OF_BOUNDS", 'invalid == nil and reason == "OUT_OF_BOUNDS"')
		assert(
			settlement.version == 0 and next(settlement.reservations) == nil,
			"settlement.version == 0 and next(settlement.reservations) == nil"
		)
		local reserved = assert(Settlement.reserve(settlement, "alice", 0, 0, {
			id = "actual",
			definition = definition,
			x = 2,
			z = 2,
			rotation = 1,
		}))
		local retained, refusal = Model.preview({ settlement = reserved }, "alice", definition, 2, 2, 1)
		assert(
			retained == reserved.reservations.actual and refusal == nil,
			"own reservation remains valid green preview"
		)
	end,
}
