--!strict
local Transport = require("../../../core/infra/genre/CommandTransport")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Job = require("../../../core/domain/crafting/Job")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local M = {}

-- The CoreGui tool hotbar (bottom 70px) wins input over every PlayerGui DisplayOrder.
M.PLACEMENT_BOTTOM = 152

-- sheets4 build sheet (Durango R06-3 Installation / Housing / Storage / Workbench / Farmland tabs):
-- every structure sits in one group tab. A definition's own `group` wins; then the pack ids below;
-- then floors / walls / roofs are shelter and any other station is a crafting station.
M.BUILD_GROUPS = { "shelter", "storage", "station", "farm", "deco" }
M.BUILD_GROUP_ICON = {
	shelter = "cat.building",
	storage = "capacity",
	station = "craft",
	farm = "cat.farm",
	deco = "favorite",
} :: { [string]: string }
local BUILD_GROUP: { [string]: string } = {
	tent = "shelter",
	bed = "shelter",
	["clan-hall"] = "shelter",
	door = "shelter",
	storage = "storage",
	refrigerator = "storage",
	["animal-pen"] = "farm",
	well = "farm",
	pillar = "deco",
	stairs = "deco",
}
-- First builds lead their tab (v61 order: floor, campfire, workbench, storage, roof).
local BUILD_PRIORITY: { [string]: number } = { floor = 1, campfire = 2, workbench = 3, storage = 4, roof = 5 }

function M.buildGroup(definition: any): string
	if type(definition.group) == "string" and table.find(M.BUILD_GROUPS, definition.group) then
		return definition.group
	end
	local id = definition.id
	if BUILD_GROUP[id] then
		return BUILD_GROUP[id]
	end
	if string.find(id, "floor$") or string.find(id, "wall$") or string.find(id, "roof$") then
		return "shelter"
	end
	return if definition.station then "station" else "shelter"
end

-- Structures of one group in card order (priority, then tier, then id).
function M.buildList(structures: { any }, group: string): { any }
	local list = {}
	for _, definition in structures do
		if M.buildGroup(definition) == group then
			table.insert(list, definition)
		end
	end
	table.sort(list, function(a: any, b: any)
		local pa, pb = BUILD_PRIORITY[a.id] or 10, BUILD_PRIORITY[b.id] or 10
		if pa ~= pb then
			return pa < pb
		end
		if (a.tier or 0) ~= (b.tier or 0) then
			return (a.tier or 0) < (b.tier or 0)
		end
		return a.id < b.id
	end)
	return list
end

-- Build card geometry in card px: 44 px art and a 2-line name, one 26 px material chip per cost
-- (30 px pitch), then the 40 px Build button. Two columns from a 540 px sheet (800x360 phone,
-- 1280x720 PC, 932 px phones) keep a chip's material name at least ~170 px wide; else one column.
M.BUILD_CARD = table.freeze({ pad = 8, art = 44, chip = 26, pitch = 30, button = 40, chipTop = 58, count = 44 })
function M.buildCardHeight(rows: number): number
	local c = M.BUILD_CARD
	return c.chipTop + rows * c.pitch + 2 + c.button + c.pad
end
function M.buildColumns(sheetWidth: number): number
	return if sheetWidth >= 540 then 2 else 1
end

-- sheets4b: the build group tabs sit in the sheet header strip between the title and Close (like the
-- skills sheet's stats strip), followed by a 36 px (?) toggle for the placement hint. The strip spans
-- from `left` px after the header's left edge to Close. Tabs are icon-only (40 px) on a touch device
-- (the 800x360 phone) or when the labelled tabs plus the toggle do not fit; the strip scrolls
-- sideways when even icon tabs overflow (portrait). The body then starts with the cards.
M.BUILD_TAB = table.freeze({ icon = 40, height = 36, gap = 4, help = 36, left = 110, right = 58, labelPad = 36 })
-- Estimated label width in px (Hangul/CJK a full em, Latin letters and digits 0.62 em, spaces 0.3,
-- other marks 0.35), the same estimate the ui-kit HudFit uses, kept here because HudFit is not
-- shipped to the place.
function M.labelWidth(text: string, size: number): number
	local width = 0
	for _, code in utf8.codes(text) do
		if
			code >= 0x1100
			and (code <= 0x115F or (code >= 0x2E80 and code <= 0xD7A3) or (code >= 0xF900 and code <= 0xFFE6))
		then
			width += size
		elseif code == 32 then
			width += size * 0.3
		elseif (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) then
			width += size * 0.62
		else
			width += size * 0.35
		end
	end
	return width
end
function M.buildTabStrip(sheetWidth: number, labels: { number }, touch: boolean): (boolean, number)
	local T = M.BUILD_TAB
	local strip = math.max(0, sheetWidth - T.left - T.right)
	local labelled = T.help
	for _, width in labels do
		labelled += T.gap + math.max(T.icon, width + T.labelPad)
	end
	return touch or labelled > strip, strip
end
-- Success line (SurvivalHUDLocale key) shown after a confirmed action.
M.SUCCESS = { ["survival-coop:item-repair"] = "repaired" } :: { [string]: string }
-- Transient refusals re-sent automatically, one second apart, before only the Retry button is left.
M.AUTO_RETRIES, M.AUTO_RETRY_SECONDS = 10, 1
-- Session / Executor refusals that mean "busy, send the same request again" (core/infra/genre/Session,
-- core/domain/genre/Executor debitRate, GatheringBridge SOURCE_BUSY).
M.TRANSIENT = table.freeze({
	COMMAND_PENDING = true,
	COMBAT_PENDING = true,
	-- An accepted swing in its windup: the same request settles once the blow resolves.
	WINDUP = true,
	SERVER_EVENT_PENDING = true,
	TRANSFER_PENDING = true,
	SOURCE_BUSY = true,
	["rate limited"] = true,
	["profile operation in progress"] = true,
}) :: { [string]: boolean }
-- Idempotent personal toggles (RecipeMarks, StanceExtension): they commit without a stateVersion,
-- so Transport.settle never ends them and a replay re-applies the same value. Any answer that is
-- not a transient refusal is final. Staging v40: a committed recipe-mark stayed 'pending' for
-- 90 s on two servers and locked craft and eat (every mutation is disabled while pending).
M.TOGGLES = table.freeze({
	["survival-coop:recipe-mark"] = true,
	["survival-coop:stance-set"] = true,
}) :: { [string]: boolean }

-- One-click hand craft: the next verb, args and delay after a HUD craft result (reserve -> start -> collect).
function M.handChain(
	request: any,
	result: any,
	hand: { [string]: number? },
	recipes: { any }
): (string?, { any }?, number?)
	local action, id = string.sub(request.action, 15), request.args[1]
	if action == "craft-reserve" then
		id = request.args[2] == "hand" and result and result.ok and result.data.jobId
		for _, r in recipes do
			if id and r.id == request.args[1] then
				hand[id] = r.craftMillis / 1000 + 0.5
				return "craft-start", { id }, 0
			end
		end
	elseif hand[id] and result then
		local wait: number? = if action == "craft-start" and result.ok
			then hand[id]
			elseif action == "craft-complete" and result.reason == "NOT_READY" then 1
			else nil
		hand[id] = if wait then hand[id] else nil
		return if wait then "craft-complete" else nil, { id }, wait
	end
	return nil
end

function M.stationTarget(position: any, size: any): any
	return { x = position.x, y = position.y + size.y / 2 + 2, z = position.z }
end

function M.new(actor: string, newId: () -> string): any
	local model: any = {
		actor = actor,
		snapshot = {},
		durable = nil,
		revision = -1,
		pending = nil,
		busy = false,
		status = "loading",
		reason = nil,
	}
	function model.receive(packet: any): boolean
		if packet.revision and packet.revision < model.revision then
			return false
		end
		if packet.durable then
			model.durable = packet.durable
			-- A policy ends a handshake failure from a server swap (else the banner stuck all session).
			if model.status == "conflict" and model.reason == "HANDSHAKE_FAILED" then
				model.status, model.reason = if model.pending then "pending" else "ready", nil
			end
		end
		if packet.snapshots and packet.snapshots["survival-coop"] then
			model.snapshot = table.clone(packet.snapshots["survival-coop"])
			model.snapshot.contracts = packet.snapshots.survivalExtensions
				and packet.snapshots.survivalExtensions.contracts
			model.snapshot.recipeMarks = packet.snapshots.survivalExtensions
				and packet.snapshots.survivalExtensions["recipe-marks"]
			model.snapshot.extensionPin = M.extensionPin(packet.snapshots.survivalExtensions)
			model.snapshot.buildPin = M.extensionBuildPin(packet.snapshots.survivalExtensions)
			local shared = packet.snapshots.survivalSettlement
			if shared then
				model.snapshot.settlement, model.snapshot.warehouse = shared.settlement, shared.warehouse
			end
			model.revision = packet.revision or model.revision
			if model.status == "loading" then
				model.status = "ready"
			end
		end
		return true
	end
	function model.begin(verb: string, args: { any }): any
		if model.busy or model.pending then
			return nil
		end
		local action = "survival-coop:" .. verb
		local policy = model.durable
		local epoch = if policy and policy.epochs
			then policy.epochs[action]
			else if policy then policy.sessionEpoch else nil
		if not Transport.durable(policy, action) or type(epoch) ~= "number" then
			model.status, model.reason = "conflict", "HANDSHAKE_FAILED"
			return nil
		end
		local request = Transport.request(nil, action, args, epoch, newId)
		table.freeze(request.args)
		table.freeze(request)
		model.pending, model.busy, model.status, model.reason = request, true, "pending", nil
		model.notice, model.autoRetries = nil, nil
		return request
	end
	function model.retry(): any
		if model.busy or not model.pending then
			return nil
		end
		model.busy, model.status = true, "pending"
		return model.pending
	end
	--- The retained request after a transient server refusal, for the HUD to re-send by itself
	--- (same requestId, so a late commit replays instead of applying twice). Nil once it settled,
	--- while one is in flight, or after M.AUTO_RETRIES tries (the Retry button stays).
	function model.autoRetry(): any
		if not model.autoRetries or model.autoRetries > M.AUTO_RETRIES then
			return nil
		end
		return model.retry()
	end
	function model.finish(ok: boolean, result: any)
		model.busy = false
		model.notice = nil
		if not ok or type(result) ~= "table" then
			model.status, model.reason = "pending", "TRANSPORT_FAILED"
			return
		end
		local action = if model.pending then model.pending.action else nil
		model.pending = Transport.settle(model.pending, result)
		-- A personal extension (repair, drop) commits without a stateVersion: an accepted result that
		-- is not an in-flight phase is final, so a retry cannot replay it into a refusal.
		local phase = if type(result.data) == "table" then result.data.status else nil
		if
			result.ok
			and (action == "survival-coop:item-repair" or action == "survival-coop:item-drop")
			and phase ~= "pending"
			and phase ~= "recovering"
		then
			model.pending = nil
		end
		if action and M.TOGGLES[action] and not M.TRANSIENT[result.reason] then
			model.pending = nil
		end
		-- Transfer settles in another owner and exposes its phase. A rejected grant is final
		-- (a replay refuses again); keeping it pending locked every HUD action (2026-10-18).
		if
			result.data
			and (
				(result.ok and result.data.status == "confirmed")
				or (not result.ok and result.data.status == "rejected")
			)
		then
			model.pending = nil
		end
		model.reason = if result.ok then nil else result.reason
		-- A busy-server refusal (no stateVersion: nothing was recorded) keeps the same request pending.
		-- Its code has no HUD line and read as "refresh supplies" while nothing re-sent it (staging
		-- v37/v38 craft): the pending headline says it all, and the HUD re-sends it (autoRetry).
		if model.pending and not result.ok and M.TRANSIENT[result.reason] then
			model.reason = nil
			model.autoRetries = (model.autoRetries or 0) + 1
		else
			model.autoRetries = nil
		end
		if result.ok and not model.pending then
			model.notice = M.SUCCESS[action]
		end
		if result.ok and result.data and result.data.notificationError then
			model.reason = "SETTLEMENT_PUBLICATION_FAILED"
		end
		model.status = if model.pending then "pending" elseif result.ok then "confirmed" else "conflict"
		if result.reason == "REQUEST_EXPIRED" then
			model.durable = nil
		end
	end
	--- Clears a success line once its display time has passed, unless a newer result or an
	--- in-flight request replaced it. Returns whether the line was cleared.
	function model.expireNotice(notice: string): boolean
		if model.notice ~= notice or model.pending or model.busy then
			return false
		end
		model.notice = nil
		return true
	end
	--- Clears an expired refusal line unless a newer result or request replaced it; true if cleared.
	function model.expireRefusal(reason: string): boolean
		if model.status ~= "conflict" or model.reason ~= reason or model.pending or model.busy then
			return false
		end
		model.status, model.reason = "ready", nil
		return true
	end
	return model
end

function M.bag(snapshot: any): any
	for _, bag in snapshot.inventory or {} do
		if bag.kind == "carried" then
			return bag
		end
	end
	return nil
end

function M.repairCost(item: any, content: any): number?
	for _, op in content.operations or {} do
		for _, def in if op.kind == "repair" then content.items else {} do
			local eligible = op.eligibleTags == nil
			for _, tag in op.eligibleTags or {} do
				eligible = eligible or table.find(def.tags or {}, tag) ~= nil
			end
			if def.id == item.catalogId and eligible and item.durabilityMilli < Catalog.maxDurability(def, item) then
				return Job.repairCost(op, item.catalogId)
			end
		end
	end
	return nil
end

function M.items(bag: any): { any }
	local rows = {}
	if not bag then
		return rows
	end
	for id, item in bag.items do
		local reserved = 0
		for _, amounts in bag.reservations do
			reserved += amounts[id] or 0
		end
		table.insert(rows, { item = item, reserved = reserved, available = item.quantity - reserved })
	end
	table.sort(rows, function(a, b)
		return a.item.itemId < b.item.itemId
	end)
	return rows
end

function M.jobs(snapshot: any, actor: string): { any }
	local rows = {}
	local workshop = snapshot.workshop
	if workshop and workshop.actorId == actor then
		for id, entry in workshop.entries do
			if entry.job.state ~= "Committed" and entry.job.state ~= "Cancelled" then
				table.insert(rows, { id = id, job = entry.job })
			end
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

--- Total quantity of one catalog item across every stack in the bag (reserved units included):
--- the craft panel's output row shows it, not the size of a single stack.
function M.held(bag: any, catalogId: string): number
	local total = 0
	for _, row in M.items(bag) do
		if row.item.catalogId == catalogId then
			total += row.item.quantity
		end
	end
	return total
end

function M.ingredients(bag: any, recipe: any): { any }
	local rows = {}
	for _, input in recipe.inputs do
		local available = 0
		for _, row in M.items(bag) do
			if row.item.catalogId == input.item then
				available += row.available
			end
		end
		table.insert(rows, { id = input.item, needed = input.quantity, available = available })
	end
	return rows
end

function M.missingMaterials(bag: any, inputs: { any }): { any }
	local missing = {}
	for _, ingredient in M.ingredients(bag, { inputs = inputs }) do
		if ingredient.available < ingredient.needed then
			table.insert(missing, ingredient)
		end
	end
	return missing
end

--- Build cost rows (p134 C1 dead end 3): warehouse stock, plus the carried bag when the pack pays
--- builds from the bag (the onboarding server deposits the shortfall on reserve). `fromBag` on a row
--- is how many of it the bag adds; `bagUsed` is true when the bag covers any shortfall.
function M.buildCosts(warehouse: any, bag: any, cost: { any }, bagBuild: boolean?): ({ any }, boolean)
	local rows = M.ingredients(warehouse, { inputs = cost })
	local carried = if bagBuild then M.ingredients(bag, { inputs = cost }) else {}
	local bagUsed = false
	for index, row in rows do
		local extra =
			math.min(carried[index] and carried[index].available or 0, math.max(0, row.needed - row.available))
		row.fromBag = extra
		row.available += if carried[index] then carried[index].available else 0
		bagUsed = bagUsed or extra > 0
	end
	return rows, bagUsed
end

--- The cell a placement starts on: the footprint under the player (clamped so the footprint and its
--- entry, one cell before the origin, stay on the grid), not the grid corner.
function M.startCell(
	px: number,
	pz: number,
	originX: number,
	originZ: number,
	config: any,
	definition: any
): (number, number)
	local x, z = M.pointerCell(px, pz, originX, originZ, config)
	return math.clamp(x, 0, config.width - definition.footprintX),
		math.clamp(z, 1, config.depth - definition.footprintZ)
end

function M.pointerCell(hitX: number, hitZ: number, originX: number, originZ: number, config: any): (number, number)
	return math.clamp(math.floor((hitX - originX) / config.cellStuds), 0, config.width - 1),
		math.clamp(math.floor((hitZ - originZ) / config.cellStuds), 0, config.depth - 1)
end

function M.overPlacementBar(x: number, y: number, p: any, s: any): boolean
	return x >= p.X - 12 and x <= p.X + s.X + 12 and y >= p.Y - 12 and y <= p.Y + s.Y + 12
end

function M.placements(settlement: any, actor: string): { any }
	local rows = {}
	for id, placement in settlement.reservations do
		if placement.actorId == actor then
			table.insert(rows, { id = id, placement = placement })
		end
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

M.STACK_BOTTOM = 180

-- Fullness (hungerMilli / 1000) below this shows the eat prompt.
M.HUNGRY_BELOW = 30
--- True when the vitals call for a food prompt.
function M.hungry(vitals: any): boolean
	return type(vitals) == "table"
		and type(vitals.hungerMilli) == "number"
		and vitals.hungerMilli / 1000 < M.HUNGRY_BELOW
end

--- Which hungry line fits the bag (p134 v53: the player starved holding no food and never learnt
--- that raw meat cooks at a campfire): "hungry" (something edible is carried), "hungry_cook"
--- (only raw meat), "hungry_find" (nothing to eat), or nil when not hungry.
--- True when the item wears out (its content row has maxDurabilityMilli); materials and food do not.
function M.wears(content: any, catalogId: string): boolean
	for _, item in if type(content) == "table" then content.items or {} else {} do
		if item.id == catalogId then
			return type(item.maxDurabilityMilli) == "number" and item.maxDurabilityMilli > 0
		end
	end
	return false
end

function M.hungerHint(snapshot: any, items: { any }?): string?
	if type(snapshot) ~= "table" or not M.hungry(snapshot.vitals) then
		return nil
	end
	local edible: { [string]: boolean } = {}
	for _, definition: any in (items or {}) :: { any } do
		if definition.foodEffects then
			edible[definition.id] = true
		end
	end
	local bag = type(snapshot.inventory) == "table" and snapshot.inventory.bag
	local meat = false
	for _, item in if type(bag) == "table" and type(bag.items) == "table" then bag.items else {} do
		if edible[item.catalogId] then
			return "hungry"
		end
		meat = meat or item.catalogId == "meat"
	end
	return if meat then "hungry_cook" else "hungry_find"
end

--- Durable death count of a survival snapshot (deathBundles.lastSequence counts every death,
--- bag dropped or not); nil until the first snapshot with vitals has arrived.
function M.deathSequence(snapshot: any): number?
	if type(snapshot) ~= "table" or type(snapshot.vitals) ~= "table" then
		return nil
	end
	local bundles = snapshot.deathBundles
	return if type(bundles) == "table" and type(bundles.lastSequence) == "number" then bundles.lastSequence else 0
end

--- True when a death was committed since `before` and the actor is up again. With no respawn
--- delay the server revives and reloads the character within a frame, so no snapshot ever shows
--- zero health and the knockout panel never opens (p76 Studio: two silent returns to spawn).
function M.knockedDown(before: number?, snapshot: any): boolean
	local after = M.deathSequence(snapshot)
	return before ~= nil
		and after ~= nil
		and after > before
		and type(snapshot.vitals.healthMilli) == "number"
		and snapshot.vitals.healthMilli > 0
end

--- The tutorial's axe pin: the Flint Hatchet unless the bag holds the starter axe's branch + stone.
function M.axePin(bag: any, recipes: { any }): string
	local starter, hatchet = nil, nil
	for _, recipe in recipes do
		starter = if recipe.id == "starter-axe" then recipe else starter
		hatchet = if recipe.id == "stone-axe" then recipe else hatchet
	end
	if starter and (not hatchet or #M.missingMaterials(bag, starter.inputs) == 0) then
		return "starter-axe"
	end
	return "stone-axe"
end

--- Recipe a pack extension asks the craft sheet to preselect: the first extension snapshot (by id)
--- publishing a string `craftPin` (Robango's opening tracker: the Bone Knife while it asks for one).
function M.extensionPin(extensions: any): string?
	if type(extensions) ~= "table" then
		return nil
	end
	local ids = {}
	for id, view in extensions do
		if type(id) == "string" and type(view) == "table" and type(view.craftPin) == "string" then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return if ids[1] then extensions[ids[1]].craftPin else nil
end

--- Structure a pack extension asks the build sheet to open on: the first extension snapshot (by id)
--- publishing a string `buildPin` (Robango's opening tracker: the campfire while it asks for one).
function M.extensionBuildPin(extensions: any): string?
	if type(extensions) ~= "table" then
		return nil
	end
	local ids = {}
	for id, view in extensions do
		if type(id) == "string" and type(view) == "table" and type(view.buildPin) == "string" then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return if ids[1] then extensions[ids[1]].buildPin else nil
end

--- The build tab the sheet opens on for a snapshot: the group of the pinned structure (an extension's
--- buildPin) when it is in `structures`, else nil (the sheet keeps its last tab).
function M.buildPinGroup(snapshot: any, structures: { any }): string?
	local pin = type(snapshot) == "table" and snapshot.buildPin or nil
	if type(pin) ~= "string" then
		return nil
	end
	for _, definition in structures do
		if definition.id == pin then
			return M.buildGroup(definition)
		end
	end
	return nil
end

--- The craft sheet's pinned (preselected) recipe for a snapshot: an extension's pin wins (p134 C1:
--- the sheet opened on the Flint Hatchet while the opening tracker asked for the Bone Knife), then
--- the tutorial's axe step pin; nil pins nothing.
function M.craftPin(snapshot: any, bag: any, recipes: { any }): string?
	if type(snapshot) ~= "table" then
		return nil
	end
	if type(snapshot.extensionPin) == "string" then
		return snapshot.extensionPin
	end
	local tutorial = snapshot.contracts and snapshot.contracts.tutorial
	return if tutorial and tutorial.step == "craft-stone-axe" then M.axePin(bag, recipes) else nil
end

function M.recipeOrder(
	bag: any,
	recipes: { any },
	stationAvailable: (string) -> boolean,
	items: { any }?,
	filter: any?
): { any }
	local rows = {}
	for _, recipe in recipes do
		local stationReady = recipe.station == nil or stationAvailable(recipe.station)
		local ready, complete, held = stationReady, true, false
		for _, ingredient in M.ingredients(bag, recipe) do
			complete = complete and ingredient.available >= ingredient.needed
			held = held or ingredient.available > 0
		end
		ready = ready and complete
		local skill: string? = nil
		for _, d in if filter and filter.progression then filter.details else {} do
			for _, n in if d.id == recipe.id then d.skillNodes else {} do
				skill = skill or (if filter.progression.paid[n] then nil else n)
			end
		end
		ready = ready and skill == nil
		if recipe.requiredToolTag then
			local tool = false
			for _, row in M.items(bag) do
				for _, definition in (items or {}) :: { any } do
					tool = tool
						or (
							definition.id == row.item.catalogId
							and row.available > 0
							and row.item.durabilityMilli > 0
							and table.find(definition.tags, recipe.requiredToolTag) ~= nil
						)
				end
			end
			ready = ready and tool
		end
		local favorite = filter ~= nil and filter.favorites ~= nil and filter.favorites[recipe.id] == true
		if
			not filter
			or filter.all
			or favorite
			or recipe.id == filter.pin
			or (filter.jobs and filter.jobs[recipe.id])
			or complete
			-- Station recipes surface in range only once an input is held; bare hand recipes never do.
			or (recipe.station ~= nil and stationReady and held)
		then
			table.insert(rows, {
				recipe = recipe,
				ready = ready,
				stationReady = stationReady,
				skill = skill,
				station = recipe.station or "",
				favorite = favorite,
			})
		end
	end
	table.sort(rows, function(a, b)
		if filter and (a.recipe.id == filter.pin) ~= (b.recipe.id == filter.pin) then
			return a.recipe.id == filter.pin
		end
		if a.favorite ~= b.favorite then
			return a.favorite
		end
		if a.station ~= b.station then
			return a.station < b.station
		end
		if a.ready ~= b.ready then
			return a.ready
		end
		return a.recipe.id < b.recipe.id
	end)
	return rows
end

function M.craftPanes(_width: number, height: number): any
	local h = math.max(0, height - 108)
	return { height = h, listHeight = math.floor(h * 0.4) }
end

-- Largest height <= `height` that holds whole `row`-pixel rows separated by `gap` (at least one row).
function M.wholeRows(height: number, row: number, gap: number): number
	local rows = math.max(1, math.floor((height + gap) / (row + gap)))
	return rows * (row + gap) - gap
end

-- CoreGui tool hotbar: bottom 70 px (p112)
M.HOTBAR_CLEAR = 56
function M.contextSheetBounds(width: number, height: number, touch: boolean): (number, number, number, number)
	local top = 64
	local bottom = if touch or width < 700 then 128 else M.HOTBAR_CLEAR
	if width < 600 and height > width then
		return width, math.max(44, height - top - 16), top, 0
	end
	return math.min(720, math.max(0, width - 16)), math.max(0, math.min(576, height - top - bottom)), top, 8
end

function M.chatSafe(
	width: number,
	height: number,
	x: number,
	y: number,
	w: number,
	h: number
): (number, number, number, number)
	local edge = y + h
	if width >= 1000 and x < 540 and y < 320 then
		if width - 548 >= w then
			x = 548
		else
			y = 328
		end
		h = math.max(0, math.min(h, edge - y, height - y - 8))
	end
	return x, y, w, h
end

-- Contextual sheet rect (SurvivalHUD, ExtensionPanels). Short touch landscape (320-430 tall)
-- takes the full height between the thumbstick and the jump button.
M.THUMB_GUTTER = 104
function M.contextSheet(width: number, height: number, touch: boolean): (number, number, number, number)
	if (touch or width < 700) and width > height and height < 480 then
		return M.THUMB_GUTTER, 64, width - 2 * M.THUMB_GUTTER, height - 72
	end
	local w, h, top, right = M.contextSheetBounds(width, height, touch)
	return M.chatSafe(width, height, width - right - w, top, w, h)
end

-- Roblox chat on a portrait phone (Studio 360x640: log 0,5 140x145, bar 12,167) plus margin.
M.PHONE_CHAT = { x = 0, y = 0, width = 160, height = 212 }
function M.phoneChat(width: number, height: number?): any
	if height ~= nil and height > width and width < 1000 then
		return M.PHONE_CHAT
	end
	return nil
end

-- Vitals row geometry (SurvivalHUD): optional stat icon, localized stat label beside it (never
-- under it: p105 Studio showed the heart/bolt drawn over the label), bar track, value. A Gotham
-- line box is 1.5x the text size (14px -> 21px, p105), so a 26px row holds 1.2x text (17px) too;
-- rows step 24px and overlap only in their transparent padding.
M.VITALS = {
	iconX = 4,
	iconSize = 18,
	labelX = 26,
	labelWidth = 62,
	rowTop = 0,
	rowStep = 24,
	rowHeight = 26,
	textSize = 14,
	trackX = 90,
	trackRight = 46,
}

-- Portrait objective slot: room for six wrapped 14px lines plus the chip's 6px top/bottom padding.
-- The slot is transparent and the chip auto-sizes to its text, so short objectives stay short.
-- The grade-2 next-step line wrapped past two lines in the 180px column at 360x640 and was cut (p64).
M.OBJECTIVE_TEXT_SIZE = 14
M.PORTRAIT_OBJECTIVE_LINES = 6
M.PORTRAIT_OBJECTIVE_HEIGHT = M.PORTRAIT_OBJECTIVE_LINES * M.OBJECTIVE_TEXT_SIZE + 16

function M.contextHudBounds(width: number, height: number?): any
	local chat = M.phoneChat(width, height)
	if chat then
		-- Portrait phone: every HUD rect sits in the column right of the chat window. The menu
		-- button (with the coin chip beside it) heads the column, vitals and objective follow.
		local left = chat.x + chat.width + 8
		local w = width - left - 12
		local menu = { x = width - 76, y = 64, width = 64, height = 44 }
		local vitals = { x = left, y = menu.y + menu.height + 8, width = w, height = 76 }
		local objective =
			{ x = left, y = vitals.y + vitals.height + 8, width = w, height = M.PORTRAIT_OBJECTIVE_HEIGHT }
		return {
			vitals = vitals,
			objective = objective,
			menu = menu,
			coins = { x = menu.x - 108, y = menu.y + 8, width = 100, height = 28 },
			biome = { x = left, y = 24, width = w, height = 32 },
			status = { x = left, y = objective.y + objective.height + 8, width = w, height = 56 },
			photo = {
				x = (width - math.min(520, width - 24)) / 2,
				y = 64,
				width = math.min(520, width - 24),
				height = 92,
			},
		}
	end
	local w = math.min(216, width - 100)
	return {
		vitals = { x = width - w - 12, y = 64, width = w, height = 76 },
		objective = { x = width - w - 12, y = 144, width = w, height = math.clamp((height or 720) - 418, 28, 64) },
		menu = { x = width - w - 84, y = 64, width = 64, height = 44 },
		coins = { x = width - w - 116, y = 112, width = 100, height = 28 },
		biome = { x = (width - 192) / 2, y = 24, width = 192, height = 32 },
		photo = { x = (width - math.min(520, width - 24)) / 2, y = 64, width = math.min(520, width - 24), height = 92 },
	}
end

--- ui.recipe-tracker: read-only HUD rows under the objective line; on short landscape
--- phones it sits left of the menu toggle so the thumb gutters and jump zone stay clear.
function M.trackerBounds(width: number, height: number, rows: number): any
	local hud = M.contextHudBounds(width, height)
	local h = 28 + rows * 22
	if width > height and height < 480 then
		local w = math.min(200, hud.menu.x - 8 - M.THUMB_GUTTER)
		return { x = hud.menu.x - 8 - w, y = hud.menu.y, width = w, height = h }
	end
	local column = hud.objective
	return { x = column.x, y = column.y + column.height + 8, width = column.width, height = h }
end

function M.biomeToast(previous: string, current: string, remaining: number, dt: number): (number, number)
	local left = math.max(0, (if current ~= previous then 3 else remaining) - dt)
	return left, 1 - math.min(1, left)
end

-- p134 v53/v55: in the ford herd a knife player's attack and a tap beside a dodo picked the Lv 20
-- parasaurolophus (325 HP) first. An automatic pick (the attack button, the fingertip pick around a
-- tap) only takes a creature at most AUTO_LEVEL_MARGIN levels above max(player level, the easiest
-- species); a creature the tap ray hits directly is the player's own choice and always wins.
M.AUTO_LEVEL_MARGIN = 5
function M.autoEligible(content: any, kind: any, playerLevel: number?): boolean
	local level: number? = nil
	local floor = math.huge
	for _, row in (content and content.wildlifeDetails) or {} do
		if type(row.level) == "number" then
			floor = math.min(floor, row.level)
			if row.id == kind then
				level = row.level
			end
		end
	end
	if level == nil then
		return true
	end
	return level <= math.max(playerLevel or 1, floor) + M.AUTO_LEVEL_MARGIN
end

--- The nearest eligible candidate ({ kind, distance, target }) or nil.
function M.autoTarget(content: any, candidates: { any }, playerLevel: number?): any?
	local best, distance = nil, math.huge
	for _, candidate in candidates do
		if candidate.distance < distance and M.autoEligible(content, candidate.kind, playerLevel) then
			best, distance = candidate.target, candidate.distance
		end
	end
	return best
end

-- Client search radius for a ranged target; the server rechecks the weapon's own range.
M.RANGED_STUDS = 40
M.STANCE_ORDER = { "none", "attack", "defense", "counter", "onslaught", "charge", "shoot" }

--- Next unlocked stance after the current one (cycling; "none" is always available).
function M.nextStance(view: any?): string?
	if not view then
		return nil
	end
	local start = table.find(M.STANCE_ORDER, view.current or "none") or 1
	for step = 1, #M.STANCE_ORDER do
		local id = M.STANCE_ORDER[(start + step - 1) % #M.STANCE_ORDER + 1]
		if id == "none" or (view.unlocked and view.unlocked[id]) then
			return if id == (view.current or "none") then nil else id
		end
	end
	return nil
end

--- Stance button text: "Stance: <name>" with the localized stance name.
function M.stanceLabel(_locale: string, view: any?, t: (string) -> string): string
	local current = if view then view.current or "none" else "none"
	return string.format(t("stance"), t("stance." .. current))
end

function M.contextActions(
	policy: any,
	pending: any,
	modal: boolean,
	restTarget: any,
	attackTarget: any,
	rangedTarget: any?,
	rangedReady: boolean?
): any
	local function allowed(verb: string): boolean
		return not modal
			and pending == nil
			and policy ~= nil
			and table.find(policy.actions, "survival-coop:" .. verb) ~= nil
	end
	return {
		rest = restTarget ~= nil and allowed("rest"),
		attack = attackTarget ~= nil and allowed("attack"),
		dodge = attackTarget ~= nil and allowed("dodge"),
		guard = attackTarget ~= nil and allowed("guard"),
		-- Shoot only with a ranged weapon (p134 v50: knife-only players got a refused Shoot).
		shoot = rangedTarget ~= nil and rangedReady == true and allowed("attack-ranged"),
		stance = (attackTarget ~= nil or (rangedTarget ~= nil and rangedReady == true)) and allowed("stance-set"),
	}
end

--- True when the bag holds an unbroken, unreserved brawlPolicy ranged weapon.
function M.rangedReady(bag: any, content: any): boolean
	if type(bag) ~= "table" or type(bag.items) ~= "table" then
		return false
	end
	local ranged: { [string]: boolean } = {}
	for _, row in (content and content.brawlPolicy and content.brawlPolicy.weapons) or {} do
		ranged[row.item] = true
	end
	for id, item in bag.items do
		local reserved = 0
		for _, quantities in bag.reservations or {} do
			reserved += quantities[id] or 0
		end
		if ranged[item.catalogId] and (item.durabilityMilli or 0) > 0 and (item.quantity or 0) > reserved then
			return true
		end
	end
	return false
end

function M.nearestGatherable(nodes: { any }): any
	local best = nil
	for _, node in nodes do
		if node.available and node.reachable ~= false and (best == nil or node.distance < best.distance) then
			best = node
		end
	end
	return best
end

function M.sheetBounds(width: number, height: number, stackWidth: number?): (number, number, number, number)
	local portrait = height > width
	if height < 500 and not portrait and stackWidth then
		local right = stackWidth + 8
		local room = width - right - 8
		return math.max(math.min(240, room), math.min(400, room - 160)), math.max(0, height - 60), 0, right
	end
	local top = if height < 500
		then 0
		elseif portrait then math.max(M.STACK_BOTTOM, math.floor(height * 0.58))
		else M.STACK_BOTTOM
	return math.min(400, width), math.max(0, height - top - 60), top, 0
end

function M.buildArgs(snapshot: any, definition: any, x: number, z: number, rotation: number): ({ any }?, string?)
	local state, warehouse = snapshot.settlement, snapshot.warehouse
	if not state or not warehouse then
		return nil, "SETTLEMENT_UNAVAILABLE"
	end
	return { definition.id, x, z, rotation, state.version, warehouse.version, state.membershipRevision }, nil
end

function M.preview(
	snapshot: any,
	actor: string,
	definition: any,
	x: number,
	z: number,
	rotation: number
): (any, string?)
	local state = snapshot.settlement
	if not state then
		return nil, "SETTLEMENT_UNAVAILABLE"
	end
	for _, placement in state.reservations do
		if
			placement.actorId == actor
			and placement.definition.id == definition.id
			and placement.x == x
			and placement.z == z
			and placement.rotation == rotation
		then
			return placement, nil
		end
	end
	-- Reuse authoritative pure footprint/entry rules, without publishing the candidate.
	local id = "hud-preview"
	while state.usedIds[id] do
		id ..= "-"
	end
	local candidate, reason = Settlement.reserve(
		state,
		actor,
		state.version,
		state.membershipRevision,
		{ id = id, definition = definition, x = x, z = z, rotation = rotation }
	)
	return if candidate then candidate.reservations[id] else nil, reason
end

function M.capacity(bag: any): (number, number, number, number)
	local count = 0
	for _ in bag.items do
		count += 1
	end
	return count, bag.limits.slots, bag.weightMilli or 0, bag.limits.hardWeightMilli
end

return M
