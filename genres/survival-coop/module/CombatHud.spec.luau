--!strict
-- C3 (G12) combat presentation logic: the semi-automatic attack loop pacing, damage numbers, the
-- low-health vignette, target bar values, the carcass fan and the combat HUD regions. The loop
-- only paces requests; range, cooldown and death are decided by the server (WildlifeRuntime),
-- which these specs feed back as results.
local Combat = require("./CombatHud")
local Shell = require("./HudShell")
-- Pack files through an untyped require (other packs' roblox projects do not map robango paths).
local Content: any = (require :: any)("../../../games/robango-island/src/shared/SurvivalContent")

local function nearly(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

return {
	["a tap engages: approach when far, swing in reach, never two swings in flight"] = function()
		local s = Combat.engage(nil, "rex-1", 10)
		assert(s.auto and s.target == "rex-1" and s.nextAt == 10, "engaged now")
		assert(Combat.step(s, 10, true, 20) == "approach", "far target is approached first")
		s.approachUntil = 10 + Combat.APPROACH_SECONDS
		assert(Combat.step(s, 11, true, 20) == "wait", "one approach at a time")
		assert(Combat.step(s, 15, true, 20) == "approach", "a stalled approach is retried")
		assert(Combat.step(s, 15, true, Combat.REACH) == "swing", "in reach swings")
		s.inFlight = true
		assert(Combat.step(s, 15, true, 1) == "wait", "no second request while one is in flight")
		assert(Combat.step(nil, 15, true, 1) == "idle", "no session idles")
		assert(Combat.step(Combat.engage(nil, "x", 0), 1, false, 1) == "idle", "dead target idles")
		local again = Combat.engage(s, "rex-1", 99)
		assert(again.nextAt == s.nextAt, "re-tapping the same target keeps its pacing")
		assert(Combat.engage(s, "rex-2", 99).nextAt == 99, "a new target starts fresh")
	end,

	["server results pace the loop; NEGATIVE refusals stop or reposition it"] = function()
		local s = Combat.engage(nil, "rex-1", 0)
		s.inFlight = true
		local ok = Combat.settle(s, 5, { ok = true })
		assert(ok.auto and not ok.inFlight and nearly(ok.nextAt, 5 + Combat.SWING_SECONDS), "confirmed swing paces")
		local cooldown = Combat.settle(s, 5, { ok = false, reason = "COOLDOWN" })
		assert(cooldown.auto and nearly(cooldown.nextAt, 5 + Combat.BACKOFF_SECONDS), "cooldown backs off")
		local windup = Combat.settle(s, 5, { ok = false, reason = "WINDUP" })
		assert(windup.auto, "windup is transient")
		local far = Combat.settle(s, 5, { ok = false, reason = "OUT_OF_RANGE" })
		assert(
			far.auto and far.reason == "OUT_OF_RANGE" and Combat.step(far, 5, true, 12) == "approach",
			"out of range re-approaches"
		)
		local dead = Combat.settle(s, 5, { ok = false, reason = "ALREADY_DEAD" })
		assert(not dead.auto and Combat.step(dead, 9, true, 1) == "idle", "a dead target ends the loop")
		local unarmed = Combat.settle(s, 5, { ok = false, reason = "WEAPON_UNAVAILABLE" })
		assert(not unarmed.auto, "no weapon ends the loop instead of spamming")
		local lost = Combat.settle(s, 5, nil)
		assert(lost.auto and lost.reason == "TRANSPORT", "transport failure retries later")
	end,

	["damage numbers, health fraction and vignette"] = function()
		assert(Combat.hit(52000, 47000) == 5, "5 hp lost")
		assert(Combat.hit(1000, 900) == 1, "a sliver still shows 1")
		assert(Combat.hit(47000, 52000) == nil and Combat.hit(nil, 5) == nil, "heals and first reads show nothing")
		assert(Combat.fraction(26000, 52000) == 0.5 and Combat.fraction(1, 0) == 0, "fraction")
		assert(Combat.vignette(1, false) == 0, "calm and healthy: no vignette")
		assert(Combat.vignette(1, true) == Combat.COMBAT_GLOW, "engaged: faint corner glow")
		assert(nearly(Combat.vignette(0, false), Combat.MAX_GLOW), "near death: full glow")
		assert(Combat.vignette(0.1, true) > Combat.vignette(0.3, true), "deepens as health drops")
		assert(Combat.vignette(0.2, false) > 0, "low health shows outside combat too")
	end,

	["target bar reads level and full health from content"] = function()
		local row = Content.wildlifeDetails[1]
		local level, full = Combat.species(Content, row.id)
		assert(level == row.level and full == row.health * 1000, "content level and health")
		assert(Combat.species(Content, "hunter") == nil, "legacy ids have no level")
	end,

	["carcass fan offers untaken outputs on an upward arc"] = function()
		local row = Content.wildlifeDetails[1]
		local all = Combat.offer(Content, row.id, {})
		assert(#all == #row.dropReservoirs, "every reservoir offered")
		local rest = Combat.offer(Content, row.id, { [all[1].item] = true })
		assert(#rest == #all - 1 and rest[1].item == all[2].item, "taken outputs drop out")
		local spots = Combat.fan(3, 100, 200, 50)
		assert(#spots == 3, "one spot per output")
		for _, spot in spots do
			assert(spot.y < 200, "opens upward, the body stays visible below")
		end
		assert(nearly(spots[2].x, 100) and nearly(spots[1].x - 100, 100 - spots[3].x), "symmetric about up")
		local one = Combat.fan(1, 0, 0, 10)
		assert(nearly(one[1].x, 0) and nearly(one[1].y, -10), "a single output sits straight up")
		local wide = Combat.fan(8, 0, 0, 10)
		assert(wide[1].y > -10 and wide[8].y > -10 and #wide == 8, "span capped at the spec width")
	end,

	["combat regions: target bar top-centre, step-back pill clear of the HUD"] = function()
		local REGIONS = { "vitals", "chips", "tracker", "status", "minimap", "coords", "quest", "row", "cluster" }
		local sizes: { { any } } =
			{ { 1920, 1080, 58, false }, { 1280, 720, 36, false }, { 850, 411, 0, true }, { 640, 360, 0, true } }
		for _, size in sizes do
			local r = Shell.regions(size[1], size[2], size[3], size[4])
			for _, id in { "target", "endCombat" } do
				assert(Shell.inside(r[id], size[1], size[2], size[3]), id .. " inside " .. size[1])
				for _, other in REGIONS do
					assert(
						not Shell.overlaps(r[id], r[other]),
						string.format("%s overlaps %s at %d", id, other, size[1])
					)
				end
			end
			assert(not Shell.overlaps(r.target, r.endCombat), "bar and pill apart")
			assert(r.target.y <= r.status.y, "the target bar sits above the status banner")
		end
		-- PC 1920x1080 against ui-spec section 5: target TC 551,78 818x123; end-combat 1511,549 378x102.
		local pc = Shell.regions(1920, 1080, 58, false)
		assert(math.abs(pc.target.x - 551) <= 2 and math.abs(pc.target.y - 78) <= 2, "target rect")
		assert(math.abs(pc.target.width - 818) <= 2 and math.abs(pc.target.height - 123) <= 2, "target size")
		assert(math.abs(pc.endCombat.x - 1511) <= 2 and math.abs(pc.endCombat.y - 549) <= 2, "end-combat rect")
	end,

	["KO/EN copy comes from the pack strings; unknown refusals never show a raw code"] = function()
		-- The shared fixture installs the pack's strings.csv lookup (the client installs the same).
		local _packText = (require :: any)("../../../games/robango-island/PackText.fixture")
		assert(Combat.text("en-us", "end_combat") == "Step back", "EN step back")
		assert(Combat.text("ko-kr", "end_combat") == "물러서기", "KO step back (ui-spec section 7)")
		for _, key in { "level", "taken", "dodged", "carcass_title", "carcass_leave", "refused" } do
			assert(Combat.text("ko-kr", key) ~= key and Combat.text("en-us", key) ~= key, "row " .. key)
		end
		assert(Combat.refusal("ko-kr", "OUT_OF_RANGE") == "더 가까이 가세요", "specific refusal")
		assert(Combat.refusal("en-us", "SOME_NEW_CODE") == Combat.text("en-us", "refused"), "generic, not raw")
	end,
}
