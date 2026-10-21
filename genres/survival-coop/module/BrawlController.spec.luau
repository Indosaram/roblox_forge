--!strict
-- Host-only (luau-lsp lune set): the robango-island generated catalog is not mounted by other game packs; marker: require("@lune/task")
local Controller = require("./BrawlController")
local Ledger = require("./BrawlLedger")
local Data = require("../../../core/domain/genre/SerializedData")
local Combat = require("./Combat")
local Policy =
	assert(require("../../../games/robango-island/src/shared/SurvivalContent").brawlPolicy, "generated brawl policy")

local function fixture(): any
	local h: any = { now = 0, utc = 0, records = {}, replay = false, fail = false, ambiguous = false, published = 0 }
	h.store = {
		UpdateAsync = function(_: any, key: string, transform: any): any
			if h.fail then
				error("throttled")
			end
			if h.replay then
				transform(Data.clone(h.records[key]))
			end
			if h.conflict then
				transform(Data.clone(h.records[key]))
				local conflict = h.conflict
				h.conflict = nil
				conflict(h.records[key])
			end
			local candidate = transform(Data.clone(h.records[key]))
			if candidate ~= nil then
				h.records[key] = Data.clone(candidate)
			end
			if h.ambiguous then
				error("ack lost after commit")
			end
			return if candidate ~= nil then Data.clone(candidate) else nil
		end,
	}
	h.ledger = Ledger.new({
		store = h.store,
		key = function(actor: string): string
			return "p:" .. actor
		end,
		select = function(document: any): any
			return document.survival
		end,
		authorize = function(): boolean
			return true
		end,
	})
	h.connected = { a = true, b = true }
	h.positions = { a = { x = 0, y = 0, z = 0 }, b = { x = 1, y = 0, z = 0 } }
	h.sight = {}
	h.fact = nil
	function h.make(owner: string): any
		return Controller.new({
			store = h.store,
			lease = h.lease,
			owner = owner,
			leaseSeconds = 10,
			key = "arena",
			matchId = "m1",
			policy = Policy,
			now = function(): number
				return h.now
			end,
			utc = function(): number
				return h.utc
			end,
			ledger = h.ledger,
			facts = function(): any
				return { level = Policy.minimumLevel, maxHealth = 100, equipment = { durability = 9 } }
			end,
			action = function(): any
				return h.fact
			end,
			apply = function(state: any, actor: string, fact: any, allowed: any): any
				state.actors[actor].staminaMultiplier = allowed.staminaMultiplier
				if fact.kind == "mount" then
					state.actors[actor].mounted = true
				end
				if fact.attack then
					state.actors[actor].combat = { attacks = { Data.clone(fact.attack) } }
				end
				return { ok = true }
			end,
			frame = function(): any
				return {
					connected = Data.clone(h.connected),
					positions = Data.clone(h.positions),
					sight = Data.clone(h.sight),
				}
			end,
			publish = function()
				h.published += 1
			end,
			directory = {
				SetAsync = function()
					error("MemoryStore throttle")
				end,
			},
			messaging = {
				PublishAsync = function()
					error("MessagingService throttle")
				end,
			},
			topic = "brawl",
		})
	end
	function h.ready(): any
		local controller = h.make("one")
		assert(controller.acquire().ok, "acquire")
		for _, actor in { "a", "b" } do
			h.records["p:" .. actor] = { survival = { balance = 0 }, untouched = true }
			assert(controller.command(actor, "brawl-queue", {}).ok, "join")
		end
		assert(controller.start().ok, "start")
		h.now = Policy.preparationSeconds
		return controller
	end
	return h
end

return {
	["MemoryStore lease refuses foreign owner before durable acquisition"] = function()
		local h = fixture()
		local lease: any = nil
		h.lease = {
			UpdateAsync = function(_, _, transform)
				lease = transform(lease)
				return lease
			end,
		}
		local first = h.make("one")
		assert(first.acquire().ok, "first owner")
		local second = h.make("two")
		assert(second.acquire().reason == "ARENA_LEASE_BUSY", "foreign lease blocked")
		h.utc += 11
		assert(second.acquire().ok, "expired owner takeover")
		assert(first.command("a", "brawl-queue", {}).reason == "ARENA_LEASE_LOST", "old owner stopped")
	end,
	["CAS conflict takeover discards first successful transform"] = function()
		local h = fixture()
		local c = h.make("one")
		assert(c.acquire().ok, "acquire")
		h.conflict = function(record: any)
			record.generation += 1
			record.lease.sessionId = "two"
		end
		local published = h.published
		assert(not c.command("a", "brawl-queue", {}).ok, "second callback fenced")
		assert(#h.records.arena.data.match.order == 0 and published == h.published, "discarded candidate not visible")
	end,
	["lease excludes rival and stale owner transform never publishes"] = function()
		local h = fixture()
		local a, b = h.make("one"), h.make("two")
		assert(a.acquire().ok and not b.acquire().ok, "single owner")
		h.utc = 10
		assert(b.acquire().ok, "expired takeover")
		local published = h.published
		assert(not a.command("a", "brawl-queue", {}).ok, "stale write")
		assert(h.published == published and #b.snapshot().order == 0, "no stale effects")
	end,
	["CAS replay and failed commit do not publish candidate"] = function()
		local h = fixture()
		h.replay = true
		local c = h.ready()
		assert(#c.snapshot().order == 2, "replayed admission")
		local published = h.published
		h.fail = true
		assert(not c.disconnect("a").ok, "commit failure")
		assert(c.snapshot().actors.a.alive and h.published == published, "candidate isolated")
	end,
	["simultaneous existing combat hits draw and never consume originals"] = function()
		local h = fixture()
		local c = h.ready()
		for _, pair in { { "a", "b" }, { "b", "a" } } do
			local attack = Combat.begin(pair[1], pair[2], {
				mode = "melee",
				windupMillis = 1,
				recoveryMillis = 1,
				range = 6,
				facingDot = -1,
				damageMilli = 100000,
				ammo = 0,
			}, h.now * 1000, 0, h.positions[pair[1]], { x = 1, y = 0, z = 0 }, 0, false)
			h.fact = { kind = "melee", range = 6, attack = attack }
			h.sight[pair[1]] = true
			assert(c.command(pair[1], "brawl-action", { "opaque" }).ok, "attack")
		end
		h.now += 1
		assert(c.tick().ok, "frame")
		local state = c.snapshot()
		assert(state.phase == "finished" and state.winner == nil, "simultaneous draw")
		assert(state.actors.a.health == 0 and state.actors.b.health == 0, "both hit")
		assert(state.actors.a.equipment.durability == 9, "snapshot equipment")
	end,
	["missing positions refuse frame and storm dismounts already mounted actors"] = function()
		local h = fixture()
		local c = h.ready()
		h.fact = { kind = "mount", range = 0 }
		assert(c.command("a", "brawl-action", { "token" }).ok, "mount before storm")
		h.now += 360
		h.positions.b = nil
		assert(c.tick().reason == "MISSING_POSITION", "sparse frame rejected")
		assert(c.snapshot().actors.a.mounted, "failed frame isolated")
		h.positions.b = { x = 1, y = 0, z = 0 }
		assert(c.tick().ok and c.snapshot().actors.a.mounted == false, "storm dismount")
		assert(c.command("a", "brawl-action", { "token" }).reason == "WEATHER_MOUNT", "storm mount blocked")
		assert(c.tick().reason == "STALE_TICK", "duplicate timestamp")
	end,
	["crash takeover detects disconnected desertion and settles offline once"] = function()
		local h = fixture()
		local old = h.ready()
		h.utc = 10
		local c = h.make("two")
		assert(c.acquire().ok and c.snapshot().id == "m1", "recover same match")
		h.connected.a = false
		assert(c.tick().ok, "recover desertion")
		assert(c.snapshot().actors.a.deserted and c.snapshot().winner == "b", "deserter eliminated")
		assert(not c.nextMatch("m2").ok, "unsettled results preserved")
		h.ambiguous = true
		assert(not c.settle().ok, "ambiguous reward ack")
		h.ambiguous = false
		assert(c.settle().ok, "offline settle")
		assert(c.settle().ok, "offline replay")
		assert(h.records["p:a"].survival.balance == Policy.participationReward, "once participation")
		assert(h.records["p:b"].survival.balance == Policy.participationReward + Policy.winReward, "once winner")
		assert(h.records["p:a"].survival.brawl.days["0"] == 1, "quota once")
		assert(not old.disconnect("b").ok, "old owner fenced")
		assert(c.nextMatch("m2").ok and c.snapshot().phase == "queue", "next match")
	end,
	["ambiguous match commit recovers persisted queue without replaying entry"] = function()
		local h = fixture()
		local c = h.make("one")
		assert(c.acquire().ok, "acquire")
		h.ambiguous = true
		assert(not c.command("a", "brawl-queue", {}).ok, "lost acknowledgement")
		assert(#c.snapshot().order == 0, "unacknowledged candidate not published")
		h.ambiguous = false
		assert(c.acquire().ok and #c.snapshot().order == 1, "durable recovery")
		assert(c.command("a", "brawl-queue", {}).reason == "ALREADY_QUEUED", "no duplicate")
	end,
	["unverified action cannot run apply and rain forwards stamina multiplier"] = function()
		local h = fixture()
		local c = h.ready()
		assert(c.command("a", "brawl-action", { "forged" }).reason == "UNVERIFIED_ACTION", "server verification")
		h.now += 120
		h.fact = { kind = "sprint", range = 0 }
		assert(c.command("a", "brawl-action", { "sprint" }).ok, "rain action")
		assert(
			c.snapshot().actors.a.staminaMultiplier == Policy.weather[2].sprintMultiplier,
			"catalog stamina multiplier"
		)
		assert(c.disconnect("a").ok, "explicit disconnect")
		assert(c.snapshot().actors.a.deserted, "deserter persisted")
	end,
}
