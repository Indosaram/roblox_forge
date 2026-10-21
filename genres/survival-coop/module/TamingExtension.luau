--!strict
-- TamingExtension: durable wiring of TamingRuntime into the running survival-coop game.
--
-- A pack supplies its policy through `configure` (no policy: the factory stays disabled).
-- Actions (declared in module/Contract.luau, served through Session's extension seam):
--   tame-hit {wildId}        fill the stun gauge of a present, tameable wild animal
--   tame-capture {wildId}    capture it with the capture tool held in the bag
--   tame-feed {animalId, feedId}   feed a penned animal one food item (by catalog id) from the bag
--   tame-mount {animalId} / tame-dismount {}
--
-- Persistence: one Fenced record per owner ("taming-v1:<actor>") holding the penned animals,
-- the active ride, a bounded request-receipt table and the record revision `rev` (also the
-- command result stateVersion). The record is the source of truth; TamingRuntime is a cache
-- that is rebuilt whenever `rev` moves. Wild gauges are ephemeral server state (they decay).
--
-- Bag charges (tool wear, one food item) touch the personal aggregate, which is a different
-- key, so they are two-phase: the receipt (with the charge descriptor and the bag version it
-- was staged against) commits first, then the bag is charged and the receipt marked charged.
-- A retry or `recover` resumes an uncharged receipt. A charge is applied only while the bag is
-- still at the staged version, so a charge can be lost to a crash but is never applied twice.
-- Randomness is TamingRuntime's recorded seed; time is the injected ctx.nowMillis.
local Taming = require("../../../core/domain/taming/Taming")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Job = require("../../../core/domain/crafting/Job")
local Shared = require("../../../core/domain/genre/Contract")
local Fenced = require("../../../core/infra/data/FencedStore")
local Mounts = require("./Mounts")
local TamingRuntime = require("./TamingRuntime")
local Session = require("../../../core/infra/genre/Session")
local M = {}

M.SAVE_VERSION = 1
local PREFIX = "survival-coop:"
local ACTIONS = { "tame-hit", "tame-capture", "tame-feed", "tame-mount", "tame-dismount" }

export type Policy = {
	version: number,
	seed: number,
	carriedContainer: string,
	captureTool: string,
	tameable: { string },
	taming: Taming.Config,
	mounts: Mounts.Rules,
	maxWild: number,
	maxAnimalsPerOwner: number,
	maxReceipts: number,
	reachStuds: number,
	hitCooldownMillis: number,
	wildRespawnMillis: number,
}

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in value do
		result[key] = copy(item)
	end
	return result
end

local function fresh(): any
	return { version = M.SAVE_VERSION, rev = 0, animals = {}, ride = nil, receipts = {}, order = {} }
end

local function reject(reason: string, rev: number?): Shared.Result
	-- A stateVersion settles the client's retained request; without one it is retried forever.
	return { ok = false, reason = reason, stateVersion = rev, data = { status = "rejected" } }
end

local configured: Policy? = nil

--- A pack calls this once (before the bootstrap builds its extensions) with its taming policy;
--- without one the factory stays disabled.
function M.configure(policy: Policy?)
	if policy ~= nil then
		assert(policy.version == 1, "TAMING_POLICY_VERSION")
		Taming.config(policy.taming)
	end
	configured = policy
end

function M.factory(ctx: any): any
	local config = configured
	if config == nil then
		return nil
	end
	local items = Job.catalog(ctx.content)
	local runtime = TamingRuntime.new({
		taming = Taming.config(config.taming),
		mounts = Mounts.catalog(ctx.content, config.mounts),
		content = ctx.content,
		tameable = config.tameable,
		seed = config.seed,
		now = ctx.nowMillis,
		maxWild = config.maxWild,
		maxAnimalsPerOwner = config.maxAnimalsPerOwner,
		maxReceipts = config.maxReceipts,
	})
	local tamingConfig = Taming.config(config.taming)
	local tameable: { [string]: boolean } = {}
	for _, species in config.tameable do
		tameable[species] = true
	end
	local store = ctx.store()
	local tokens: { [string]: Fenced.Profile } = {}
	local departed: { [string]: boolean } = {}
	local synced: { [string]: number } = {}
	local unsettled: { [string]: boolean } = {}
	local lastHit: { [string]: number } = {}
	local seenHits: { [string]: boolean } = {}
	local seenOrder: { string } = {}
	local capturedUntil: { [string]: number } = {}
	local lastTarget: { [string]: string } = {}

	local function key(actor: string): string
		return "taming-v1:" .. actor
	end

	local function acquire(actor: string): (Fenced.Profile?, string?)
		if departed[actor] then
			return nil, "ACTOR_LEFT"
		end
		if #actor == 0 or #key(actor) > 50 then
			return nil, "INVALID_ACTOR"
		end
		local token, err = store:acquire(key(actor), function(data)
			if next(data) == nil then
				return fresh()
			end
			assert(data.version == M.SAVE_VERSION and type(data.animals) == "table", "INVALID_TAMING_SAVE")
			return data
		end)
		if token then
			tokens[actor] = token
		end
		return token, err
	end

	--- Reads the current committed record, (re)acquiring the lease when it was lost.
	local function current(actor: string): (Fenced.Profile?, string?)
		local token = tokens[actor]
		if not token then
			return acquire(actor)
		end
		local refreshed, err = store:renew(token)
		if not refreshed and err == "lease lost" then
			return acquire(actor)
		end
		if refreshed then
			tokens[actor] = refreshed
		end
		return refreshed, err
	end

	local function write(actor: string, transform: Fenced.Transform): (Fenced.Profile?, string?)
		local token = tokens[actor]
		if not token then
			local acquired, err = acquire(actor)
			if not acquired then
				return nil, err
			end
			token = acquired
		end
		local updated, err = store:update(token :: Fenced.Profile, transform)
		if not updated and err == "lease lost" then
			local acquired = acquire(actor)
			if acquired then
				updated, err = store:update(acquired, transform)
			end
		end
		if updated then
			tokens[actor] = updated
		end
		return updated, err
	end

	--- A receipt still owes work: an uncharged bag charge or an unapplied wild release.
	local function open(receipt: any): boolean
		return receipt ~= nil and (not receipt.charged or receipt.released == false)
	end

	local function sync(actor: string, profile: Fenced.Profile)
		local data = profile.data
		if synced[actor] == data.rev then
			return
		end
		runtime.forget(actor)
		local saved: { TamingRuntime.Owned } = {}
		for _, animal in data.animals do
			table.insert(saved, {
				id = animal.id,
				species = animal.species,
				owner = actor,
				pen = { startedAt = animal.pen.startedAt, readyAt = animal.pen.readyAt },
			})
		end
		table.sort(saved, function(left, right)
			return left.id < right.id
		end)
		assert(runtime.restore(actor, saved) == nil, "TAMING_RESTORE_FAILED")
		if data.ride then
			runtime.mount(actor, data.ride.animalId, nil, { pvp = false })
		end
		synced[actor] = data.rev
		for _, receipt in data.receipts do
			if open(receipt) then
				unsettled[actor] = true
			end
		end
	end

	local function ensure(actor: string): (Fenced.Profile?, string?)
		local profile, err = current(actor)
		if profile then
			sync(actor, profile)
		end
		return profile, err
	end

	-- Bag access -------------------------------------------------------------------------
	local function bagOf(actor: string): (any?, Inventory.State?, string?)
		local access = ctx.personalTransfer(actor)
		if not access then
			return nil, nil, "PERSONAL_UNAVAILABLE"
		end
		local profile, err = access.personal:refresh(access.profile())
		if not profile then
			return nil, nil, err or "PERSONAL_UNKNOWN"
		end
		access.install(profile)
		local data = profile.data.envelope.genres["survival-coop"].data
		local saved = if data.inventory then data.inventory[config.carriedContainer] else nil
		if not saved then
			return nil, nil, "BAG_UNAVAILABLE"
		end
		return access, Inventory.fromSave(saved, items), nil
	end

	local function ids(bag: Inventory.State): { string }
		local list = {}
		for id in bag.items do
			table.insert(list, id)
		end
		table.sort(list)
		return list
	end

	local function applyCharge(actor: string, charge: any): string?
		local access, _, err = bagOf(actor)
		if not access then
			return err
		end
		local profile = access.personal:refresh(access.profile())
		if not profile then
			return "PERSONAL_UNKNOWN"
		end
		local envelope = copy(profile.data.envelope)
		local data = envelope.genres["survival-coop"].data
		local bag = Inventory.fromSave(data.inventory[config.carriedContainer], items)
		if bag.version ~= charge.bagVersion or not bag.items[charge.itemId] then
			return nil -- already applied (or the item is gone): never charge twice
		end
		if charge.kind == "tool" then
			bag.items[charge.itemId].durabilityMilli = charge.durabilityMilli
			bag.version += 1
		else
			local updated, reason = Inventory.consume(bag, charge.itemId, 1, bag.version)
			if not updated then
				return reason
			end
			bag = updated
		end
		data.inventory[config.carriedContainer] = Inventory.save(bag)
		local saved, commitError = access.personal:commit(profile, profile.data.stateRevision, envelope, nil)
		if saved then
			access.install(saved)
		end
		return if not saved then commitError or "PERSONAL_UNKNOWN" else commitError
	end

	--- Charges one uncharged receipt and marks it. Returns an error reason on failure.
	local function settle(actor: string, requestId: string): string?
		local profile, readError = current(actor)
		if not profile then
			return readError or "TAMING_UNAVAILABLE"
		end
		local receipt = profile.data.receipts[requestId]
		if not receipt then
			return nil
		end
		-- A captured wild animal leaves the world through the wildlife owner (idempotent by
		-- captureId), then the receipt records it so a replay never touches the world again.
		if receipt.release and not receipt.released then
			local release = receipt.release
			local captureWild = ctx.captureWild
			if not captureWild then
				return "WILDLIFE_UNAVAILABLE"
			end
			local releaseError = captureWild(release.wildId, release.captureId, release.untilMillis)
			if releaseError then
				return releaseError
			end
			local marked, markError = write(actor, function(data)
				if data.receipts[requestId] then
					data.receipts[requestId].released = true
				end
				return data
			end)
			if not marked then
				return markError or "TAMING_UNAVAILABLE"
			end
			receipt = marked.data.receipts[requestId]
		end
		if not receipt or receipt.charged then
			return nil
		end
		local err = applyCharge(actor, receipt.charge)
		if err then
			return err
		end
		local marked, markError = write(actor, function(data)
			if data.receipts[requestId] then
				data.receipts[requestId].charged = true
			end
			return data
		end)
		return if marked then nil else markError or "TAMING_UNAVAILABLE"
	end

	-- Commit helper: state change + receipt in one fenced update ------------------------
	local function commit(
		actor: string,
		requestId: string,
		action: string,
		mutate: (any) -> any,
		charge: any?,
		release: ((any) -> any?)?
	): (Shared.Result?, string?)
		local outcome: any = nil
		local updated, err = write(actor, function(data)
			local known = data.receipts[requestId]
			if known then
				outcome = copy(known.result)
				return data
			end
			local result = mutate(data)
			data.rev += 1
			result.stateVersion = data.rev
			result.ok = true
			data.receipts[requestId] =
				{ action = action, result = copy(result), charge = charge, charged = charge == nil }
			local released = if release then release(result) else nil
			if released then
				data.receipts[requestId].release = released
				data.receipts[requestId].released = false
			end
			table.insert(data.order, requestId)
			while #data.order > config.maxReceipts do
				local oldest = data.receipts[data.order[1]]
				if oldest and (not oldest.charged or oldest.released == false) then
					break
				end
				data.receipts[table.remove(data.order, 1)] = nil
			end
			outcome = copy(result)
			return data
		end)
		if not updated then
			synced[actor] = nil
			return nil, err or "TAMING_UNAVAILABLE"
		end
		return outcome, nil
	end

	local function finish(actor: string, requestId: string, result: Shared.Result): Shared.Result
		local profile = tokens[actor]
		if profile and open(profile.data.receipts[requestId]) then
			local err = settle(actor, requestId)
			if err then
				unsettled[actor] = true
				-- Receipt and state are durable; the charge resumes on retry or recover.
				return { ok = false, reason = "CHARGE_PENDING", data = { status = "pending", detail = err } }
			end
			unsettled[actor] = nil
		end
		return result
	end

	-- Wild presence and reach --------------------------------------------------------------
	local function wildState(wildId: string): (string?, string?)
		local state = if ctx.wildlife then ctx.wildlife(wildId) else nil
		if not state or state.healthMilli <= 0 then
			return nil, "WILD_ABSENT"
		end
		if not tameable[state.catalogId] then
			return nil, "NOT_TAMEABLE"
		end
		local until_ = capturedUntil[wildId]
		if until_ and ctx.nowMillis() < until_ then
			return nil, "WILD_GONE"
		end
		return state.catalogId, nil
	end

	local function reach(actor: string, wildId: string): string?
		local world = ctx.world
		if not world or not world.wildlifeAccess then
			return nil -- no spatial source (native fixture): presence is the only gate
		end
		local access = world.wildlifeAccess(actor, wildId)
		if not access or not access.alive or not access.lineOfSight then
			return "OUT_OF_REACH"
		end
		local dx = access.position.x - access.targetPosition.x
		local dy = access.position.y - access.targetPosition.y
		local dz = access.position.z - access.targetPosition.z
		if dx * dx + dy * dy + dz * dz > config.reachStuds * config.reachStuds then
			return "OUT_OF_REACH"
		end
		return nil
	end

	local function ensureWild(wildId: string): string?
		local species, reason = wildState(wildId)
		if not species then
			return reason
		end
		if runtime.gaugeLevel(wildId) == nil then
			return runtime.spawnWild(wildId, species)
		end
		return nil
	end

	-- Command handlers -----------------------------------------------------------------------
	local handlers: { [string]: (string, string, { any }, Fenced.Profile) -> Shared.Result } = {}

	handlers["tame-hit"] = function(actor, requestId, args, profile)
		local wildId = args[1]
		local key_ = actor .. "\0" .. requestId
		if seenHits[key_] then
			return { ok = true, stateVersion = profile.data.rev, data = { replay = true } }
		end
		local now = ctx.nowMillis()
		local last = lastHit[actor]
		if last and now - last < config.hitCooldownMillis then
			return reject("COOLDOWN", profile.data.rev)
		end
		local failure = ensureWild(wildId) or reach(actor, wildId)
		if failure then
			return reject(failure, profile.data.rev)
		end
		local level, reason = runtime.hit(wildId, 1)
		if not level then
			return reject(reason or "UNKNOWN_WILD", profile.data.rev)
		end
		lastHit[actor] = now
		lastTarget[actor] = wildId
		seenHits[key_] = true
		table.insert(seenOrder, key_)
		if #seenOrder > config.maxReceipts then
			seenHits[table.remove(seenOrder, 1) :: string] = nil
		end
		return {
			ok = true,
			stateVersion = profile.data.rev,
			data = { level = level, max = tamingConfig.gaugeMax, full = level >= tamingConfig.gaugeMax },
		}
	end

	handlers["tame-capture"] = function(actor, requestId, args, profile)
		local wildId = args[1]
		local rev = profile.data.rev
		local failure = ensureWild(wildId) or reach(actor, wildId)
		if failure then
			return reject(failure, rev)
		end
		local access, bag, bagError = bagOf(actor)
		if not access or not bag then
			return reject(bagError or "PERSONAL_UNAVAILABLE", nil)
		end
		local tool: Inventory.Item? = nil
		for _, id in ids(bag) do
			local item = bag.items[id]
			if
				item.catalogId == config.captureTool
				and item.durabilityMilli > 0
				and Inventory.available(bag, id) > 0
			then
				tool = item
				break
			end
		end
		if not tool then
			return reject("NO_CAPTURE_TOOL", rev)
		end
		local attempt = runtime.capture(actor, requestId, wildId, { durabilityMilli = tool.durabilityMilli })
		if not attempt.ok then
			return reject(attempt.reason or "CAPTURE_REFUSED", rev)
		end
		local animal = if attempt.animalId then runtime.animal(attempt.animalId) else nil
		if attempt.captured and not animal and attempt.animalId then
			-- A stored receipt replayed after a failed commit: rebuild the animal from it.
			animal = {
				id = attempt.animalId,
				species = wildState(wildId) or "",
				owner = actor,
				pen = Taming.pen(tamingConfig, ctx.nowMillis()),
			}
		end
		local result, err = commit(
			actor,
			requestId,
			"tame-capture",
			function(data)
				if animal then
					data.animals[animal.id] = {
						id = animal.id,
						species = animal.species,
						pen = { startedAt = animal.pen.startedAt, readyAt = animal.pen.readyAt },
					}
				end
				return {
					data = {
						captured = attempt.captured,
						retry = attempt.retry,
						animalId = attempt.animalId,
						species = if animal then animal.species else nil,
					},
				}
			end,
			{
				kind = "tool",
				itemId = tool.itemId,
				durabilityMilli = attempt.tool.durabilityMilli,
				bagVersion = bag.version,
			},
			if ctx.captureWild
				then function(outcome: any): any?
					if not outcome.data.captured then
						return nil
					end
					-- Fixed at commit time, so every retry or replay applies the same window.
					return {
						wildId = wildId,
						captureId = actor .. ":" .. requestId,
						untilMillis = ctx.nowMillis() + config.wildRespawnMillis,
					}
				end
				else nil
		)
		if not result then
			return reject(err or "TAMING_UNAVAILABLE", nil)
		end
		if attempt.captured then
			capturedUntil[wildId] = ctx.nowMillis() + config.wildRespawnMillis
		end
		return finish(actor, requestId, result)
	end

	handlers["tame-feed"] = function(actor, requestId, args, profile)
		local animalId, feedId = args[1], args[2]
		local rev = profile.data.rev
		local animal = runtime.animal(animalId)
		if not animal or animal.owner ~= actor then
			return reject("NOT_OWNER", rev)
		end
		if Taming.isReady(animal.pen, ctx.nowMillis()) then
			return reject("ALREADY_READY", rev)
		end
		local access, bag, bagError = bagOf(actor)
		if not access or not bag then
			return reject(bagError or "PERSONAL_UNAVAILABLE", nil)
		end
		if tamingConfig.feedShortenMillis[feedId] == nil then
			return reject("UNKNOWN_FEED", rev)
		end
		local item: Inventory.Item? = nil
		for _, id in ids(bag) do
			if bag.items[id].catalogId == feedId and Inventory.available(bag, id) >= 1 then
				item = bag.items[id]
				break
			end
		end
		if not item then
			return reject("NO_FEED_ITEM", rev)
		end
		local pen, reason = runtime.feed(actor, animalId, feedId)
		if not pen then
			return reject(reason or "FEED_REFUSED", rev)
		end
		local result, err = commit(actor, requestId, "tame-feed", function(data)
			data.animals[animalId].pen = { startedAt = pen.startedAt, readyAt = pen.readyAt }
			return { data = { animalId = animalId, readyAt = pen.readyAt } }
		end, { kind = "feed", itemId = item.itemId, bagVersion = bag.version })
		if not result then
			return reject(err or "TAMING_UNAVAILABLE", nil)
		end
		return finish(actor, requestId, result)
	end

	handlers["tame-mount"] = function(actor, requestId, args, profile)
		local animalId = args[1]
		local recorded, reason = runtime.mount(actor, animalId, nil, { pvp = false })
		if not recorded then
			return reject(reason or "MOUNT_REFUSED", profile.data.rev)
		end
		local result, err = commit(actor, requestId, "tame-mount", function(data)
			data.ride = { animalId = animalId }
			return { data = { animalId = animalId, speedStuds = recorded.speedStuds, carryMilli = recorded.carryMilli } }
		end, nil)
		if not result then
			runtime.dismount(actor)
			return reject(err or "TAMING_UNAVAILABLE", nil)
		end
		return result
	end

	handlers["tame-dismount"] = function(actor, requestId, _, profile)
		if not profile.data.ride then
			return reject("NOT_MOUNTED", profile.data.rev)
		end
		runtime.dismount(actor)
		local result, err = commit(actor, requestId, "tame-dismount", function(data)
			data.ride = nil
			return { data = {} }
		end, nil)
		if not result then
			synced[actor] = nil
			return reject(err or "TAMING_UNAVAILABLE", nil)
		end
		return result
	end

	local extension: any = {
		id = "taming",
		handles = function(action: string): boolean
			return string.sub(action, 1, #PREFIX) == PREFIX
				and table.find(ACTIONS, string.sub(action, #PREFIX + 1)) ~= nil
		end,
	}

	function extension.command(actor, action, args, context, _origin, admit): Shared.Result
		local admitted = admit()
		if not admitted.ok then
			return admitted
		end
		local name = string.sub(action, #PREFIX + 1)
		local profile, err = ensure(actor)
		if not profile then
			return { ok = false, reason = err or "TAMING_UNAVAILABLE", data = { status = "pending" } }
		end
		local requestId = context.requestId
		local known = profile.data.receipts[requestId]
		if known then
			if known.action ~= name then
				return reject("REQUEST_CONFLICT", profile.data.rev)
			end
			return finish(actor, requestId, copy(known.result))
		end
		return handlers[name](actor, requestId, args, profile)
	end

	--- Speed multiplier (permille) the rider's bag load gives while mounted: the species carry
	--- raises the soft-weight threshold the existing speed penalty is measured against.
	local function loadMilli(actor: string, carryMilli: number): number
		local access = ctx.personalTransfer(actor)
		local data = if access then access.profile().data.envelope.genres["survival-coop"].data else nil
		local saved = if data and data.inventory then data.inventory[config.carriedContainer] else nil
		if not saved then
			return 1000
		end
		local bag = Inventory.fromSave(saved, items)
		local soft = bag.limits.softWeightMilli + carryMilli
		return if Inventory.weight(bag, items) > soft then 1000 - (bag.limits.speedPenaltyMilli or 0) else 1000
	end

	function extension.snapshot(actor: string): (any?, string?)
		-- Single owner per actor: the cached record is the truth, so a per-frame snapshot
		-- never costs a backend read. Only the first read (or a lost cache) acquires.
		local profile = tokens[actor]
		if not profile or synced[actor] ~= profile.data.rev then
			local ensured = ensure(actor)
			if not ensured then
				return nil, "TAMING_UNAVAILABLE"
			end
			profile = ensured
		end
		local now = ctx.nowMillis()
		local animals = {}
		for _, animal in runtime.list(actor) do
			table.insert(animals, {
				id = animal.id,
				species = animal.species,
				readyAt = animal.pen.readyAt,
				remainingMillis = Taming.remainingMillis(animal.pen, now),
				ready = Taming.isReady(animal.pen, now),
			})
		end
		local feeds = {}
		for feedId in tamingConfig.feedShortenMillis do
			table.insert(feeds, feedId)
		end
		table.sort(feeds)
		local ride = runtime.recorded(actor)
		local gauge = nil
		local targetId = lastTarget[actor]
		local level = if targetId then runtime.gaugeLevel(targetId) else nil
		if targetId and level then
			local species = if ctx.wildlife then ctx.wildlife(targetId) else nil
			gauge = {
				wildId = targetId,
				species = if species then species.catalogId else nil,
				level = level,
				max = tamingConfig.gaugeMax,
			}
		end
		return {
			rev = profile.data.rev,
			gauge = gauge,
			nowMillis = now,
			animals = animals,
			feeds = feeds,
			captureTool = config.captureTool,
			-- Read by the client stun/capture prompts: which wild species get a prompt, and its reach.
			tameable = table.clone(config.tameable),
			reachStuds = config.reachStuds,
			ride = if ride
				then {
					animalId = ride.animalId,
					species = ride.species,
					speedStuds = ride.speedStuds,
					carryMilli = ride.carryMilli,
				}
				else nil,
			-- Read by the world's Heartbeat: the server, never the client, sets WalkSpeed.
			walkSpeedStuds = if ride then ride.speedStuds else nil,
			loadMilli = if ride then loadMilli(actor, ride.carryMilli) else nil,
		},
			nil
	end

	function extension.recover(actor: string, _max: number): Shared.Result
		if departed[actor] then
			return { ok = true, data = { status = "idle" } }
		end
		if synced[actor] == nil then
			local _, err = ensure(actor)
			if err then
				return { ok = false, reason = err }
			end
		end
		if not unsettled[actor] then
			return { ok = true, data = { status = "idle" } }
		end
		local profile = tokens[actor]
		for requestId, receipt in profile.data.receipts do
			if open(receipt) then
				local err = settle(actor, requestId)
				if err then
					return { ok = false, reason = err }
				end
			end
		end
		unsettled[actor] = nil
		return { ok = true, data = { status = "settled" } }
	end
	function extension.drain(actor: string): Shared.Result
		if tokens[actor] == nil then
			return { ok = true }
		end
		return extension.recover(actor, 64)
	end
	function extension.releaseActor(actor: string): Shared.Result
		local token = tokens[actor]
		if token then
			local released, err = store:release(token)
			if not released and err ~= "lease lost" then
				return { ok = false, reason = err }
			end
		end
		tokens[actor], synced[actor], unsettled[actor] = nil, nil, nil
		departed[actor] = true
		return { ok = true }
	end
	function extension.resumeActor(actor: string): Shared.Result
		departed[actor] = nil
		local token, err = current(actor)
		return { ok = token ~= nil, reason = err }
	end

	function extension.close(): Shared.Result
		for actor, token in tokens do
			local released, err = store:release(token)
			if not released and err ~= "lease lost" then
				return { ok = false, reason = err or "TAMING_RELEASE_FAILED" }
			end
			tokens[actor] = nil
		end
		return { ok = true }
	end

	return Session.registerLifecycle(extension)
end

return M
