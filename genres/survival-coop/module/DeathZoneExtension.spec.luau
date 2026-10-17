--!strict
local Vitals = require("../../../core/domain/survival/Vitals")
local DeathZone = require("./DeathZoneExtension")
local Extensions = require("./Extensions")
local ExtensionPanels = require("./ExtensionPanels")
local Contract = require("./Contract")

local SET = "survival-coop:zone-set"

local function envelope(vitals: any): any
	return { genres = { ["survival-coop"] = { data = { vitals = vitals } } } }
end

local function configured(): any
	return Vitals.new(0, {
		hungerMillisPerUnit = 18000,
		fatigueMilliPerAction = 500,
		restMilliPerSecond = 2000,
		starvationMillisPerUnit = 5000,
		respawnDelayMillis = 0,
	})
end

type Harness = { extension: any, commits: number, installed: any?, current: () -> any, admits: number }

local function build(vitals: any, available: boolean?, commitReason: string?): Harness
	local token: any = { key = "personal:1", data = { stateRevision = 0, envelope = envelope(vitals) } }
	local harness: any = { commits = 0, installed = nil, admits = 0 }
	local personal = {
		commit = function(_self: any, profile: any, expected: number, candidate: any, _replay: any)
			harness.commits += 1
			assert(expected == profile.data.stateRevision, "commit uses the current revision")
			if commitReason then
				return profile, commitReason :: any, nil, false
			end
			local updated = { key = profile.key, data = { stateRevision = expected + 1, envelope = candidate } }
			token = updated
			return updated, nil, nil, true
		end,
		refresh = function(_self: any, profile: any)
			return profile
		end,
	}
	local port = {
		personal = personal,
		profile = function()
			return token
		end,
		install = function(profile: any)
			harness.installed = profile
		end,
	}
	harness.extension = assert(DeathZone.factory({
		personalTransfer = function(_actor: string)
			return if available == false then nil else port
		end,
		nowMillis = function()
			return 5000
		end,
	}))
	harness.current = function()
		return token.data.envelope.genres["survival-coop"].data.vitals
	end
	return harness :: Harness
end

local function admit(h: Harness): () -> any
	return function()
		h.admits += 1
		return { ok = true }
	end
end

local function run(h: Harness, zone: any): any
	return h.extension.command("1", SET, { zone }, {}, "client", admit(h))
end

return {
	["zone-set is the only handled action"] = function()
		local h = build(configured())
		assert(h.extension.handles(SET), "handles zone-set")
		assert(not h.extension.handles("survival-coop:shop-sync"), "ignores other actions")
	end,
	["entering and leaving danger commits the saved vitals zone"] = function()
		local h = build(configured())
		assert(run(h, "danger").ok, "enter danger")
		assert(h.current().zone == "danger", "danger persisted in the envelope")
		assert(h.current().clockMillis == 5000, "vitals advanced to the authoritative clock before the commit")
		assert(h.installed ~= nil and h.commits == 1, "committed once and installed")
		assert(h.extension.snapshot("1").zone == "danger", "snapshot reports danger")
		assert(run(h, "safe").ok, "leave danger")
		assert(h.current().zone == "safe" and h.commits == 2, "safe persisted")
	end,
	["the persisted zone selects the death policy"] = function()
		local h = build(configured())
		assert(run(h, "danger").ok, "enter danger")
		local dead = table.clone(h.current())
		dead.healthMilli = 0
		assert(Vitals.deathPolicy(dead).dropBag, "danger drops the bag with no newcomer protection")
		local safe = table.clone(configured())
		safe.healthMilli = 0
		assert(not Vitals.deathPolicy(safe).dropBag, "safe keeps the bag")
	end,
	["invalid zone input is rejected before admission or commit"] = function()
		local h = build(configured())
		local bads: { any } = { "", "Danger", "pvp", 1, true }
		for _, bad in bads do
			local result = run(h, bad)
			assert(not result.ok and result.reason == "INVALID_ZONE", "typed error for " .. tostring(bad))
		end
		assert(h.extension.command("1", SET, {}, {}, "client", admit(h)).reason == "INVALID_ZONE", "missing zone")
		assert(h.commits == 0 and h.admits == 0, "nothing admitted or committed")
		assert(h.current().zone == "safe", "state unchanged")
	end,
	["an unchanged zone commits nothing"] = function()
		local h = build(configured())
		assert(run(h, "safe").ok and h.commits == 0, "already safe is a no-op success")
	end,
	["refusals are typed and leave state unchanged"] = function()
		local plain = Vitals.new(0)
		assert(run(build(plain), "danger").reason == "ZONE_NOT_CONFIGURED", "no death group means no zone")
		assert(run(build(configured(), false), "danger").reason == "ZONE_UNAVAILABLE", "no personal port")
		local dead = configured()
		dead.healthMilli = 0
		local d = build(dead)
		assert(run(d, "danger").reason == "NOT_ALIVE" and d.commits == 0, "a dead actor cannot change zone")
		local failing = build(configured(), true, "STALE_PERSONAL_REVISION")
		assert(run(failing, "danger").reason == "STALE_PERSONAL_REVISION", "commit failure surfaces")
		assert(failing.installed == nil and failing.current().zone == "safe", "failed commit installs nothing")
		local refused = build(configured()).extension.command("1", SET, { "danger" }, {}, "client", function()
			return { ok = false, reason = "rate limited" }
		end)
		assert(not refused.ok and refused.reason == "rate limited", "admission refusal passes through")
	end,
	["the extension and its action are registered in the genre seams"] = function()
		assert(table.find(Contract.extensionActions :: { string }, "zone-set"), "extension action declared")
		local declared = false
		for _, action in Contract.actions do
			if action.id == "zone-set" then
				declared = action.origin == "client" and #action.args == 1
			end
		end
		assert(declared, "zone-set descriptor is a client action with one argument")
		assert(table.find(Extensions.factories, DeathZone.factory), "server factory registered")
		local panel = require("./DeathZonePanel")
		assert(table.find(ExtensionPanels.factories, panel.factory), "panel factory registered")
	end,
	["panel text resolves every key in both locales and the confirm gate precedes danger"] = function()
		local Panel = require("./DeathZonePanel")
		for _, key in Panel.keys do
			assert(Panel.text("en", key) ~= key and Panel.text("ko", key) ~= key, "localized " .. key)
		end
		assert(
			Panel.refusal("en", "INVALID_ZONE") == Panel.text("en", "zone_failed"),
			"typed refusal maps to a message"
		)
		assert(Panel.nextStep("safe") == "confirm", "entering danger asks for confirmation first")
		assert(Panel.nextStep("danger") == "leave", "leaving danger needs no warning")
	end,
}
