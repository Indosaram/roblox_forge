--!strict
local Rng = require("../random/Rng")
local Taming = require("./Taming")

local function config(overrides: { [string]: any }?): Taming.Config
	local raw: any = {
		gaugeMax = 100,
		fillPerHit = 25,
		decayStepMillis = 1000,
		successPermille = 400,
		toolWearMilli = 150,
		penMillis = 600000,
		feedShortenMillis = { berry = 60000, stew = 180000 },
	}
	if overrides then
		for key, value in overrides do
			raw[key] = value
		end
	end
	return Taming.config(raw)
end

local function full(c: Taming.Config, now: number): Taming.Gauge
	return Taming.hit(c, Taming.newGauge(now), now, 4)
end

return {
	["gauge fills from hits clamps at full and decays on the caller clock"] = function()
		local c = config()
		local gauge = Taming.newGauge(0)
		gauge = Taming.hit(c, gauge, 0)
		assert(gauge.level == 25 and not Taming.isFull(c, gauge, 0), "one hit fills one quarter")
		gauge = Taming.hit(c, gauge, 0, 10)
		assert(gauge.level == 100 and Taming.isFull(c, gauge, 0), "clamped at full")
		assert(Taming.level(c, gauge, 999) == 100, "no decay before one step")
		assert(Taming.level(c, gauge, 1000) == 99 and not Taming.isFull(c, gauge, 1000), "one step drains one unit")
		assert(
			Taming.level(c, gauge, 100000) == 0 and Taming.level(c, gauge, 10 ^ 9) == 0,
			"drains to zero, never below"
		)
		local later = Taming.hit(c, gauge, 1500)
		assert(later.level == 100 and later.at == 1000, "decay settles by whole steps, partial step kept")
		local again = Taming.hit(c, later, 1999, 1)
		assert(again.level == 100, "fill after decay re-clamps")
		assert(gauge.level == 100 and gauge.at == 0, "input gauge is never mutated")
	end,
	["partial decay steps are never lost across repeated settling"] = function()
		local c = config()
		local direct = Taming.level(c, full(c, 0), 5000)
		local gauge = full(c, 0)
		for t = 500, 5000, 500 do
			gauge = Taming.hit(c, gauge, t, 1)
			gauge.level = math.min(gauge.level, 100)
		end
		assert(direct == 95, "five whole steps drain five units")
		assert(Taming.level(c, Taming.newGauge(0), 10 ^ 6) == 0, "an empty gauge stays empty")
	end,
	["NEGATIVE: capture is refused while the gauge is not full and consumes nothing"] = function()
		local c = config()
		local rng = Rng.new(1)
		local before = rng:state()
		local gauge = Taming.hit(c, Taming.newGauge(0), 0, 3)
		local result = Taming.capture(c, gauge, 0, rng, { durabilityMilli = 1000 })
		assert(not result.ok and result.reason == "GAUGE_NOT_FULL", "refused at 75%")
		assert(not result.captured and not result.fled and not result.retry, "no capture, no flee, no retry")
		assert(result.tool.durabilityMilli == 1000, "tool untouched on refusal")
		assert(table.concat(rng:state(), ",") == table.concat(before, ","), "no random draw on refusal")
		local drained = Taming.capture(c, full(c, 0), 1000, rng, { durabilityMilli = 1000 })
		assert(not drained.ok and drained.reason == "GAUGE_NOT_FULL", "full gauge that decayed is refused")
		local empty = Taming.capture(c, Taming.newGauge(0), 0, rng, { durabilityMilli = 1000 })
		assert(empty.reason == "GAUGE_NOT_FULL", "empty gauge refused")
	end,
	["failure consumes only durability and leaves a retry state with no flee"] = function()
		local c = config({ successPermille = 0 })
		local rng = Rng.new(5)
		local gauge = full(c, 0)
		local held = { durabilityMilli = 500 }
		local first = Taming.capture(c, gauge, 0, rng, held)
		assert(first.ok and not first.captured and first.retry and not first.fled, "failed roll is a retry")
		assert(
			first.tool.durabilityMilli == 350 and held.durabilityMilli == 500,
			"only the tool wears, input untouched"
		)
		assert(first.gauge.level == 100, "gauge stays full for the retry")
		local second = Taming.capture(c, first.gauge, 0, rng, first.tool)
		local third = Taming.capture(c, second.gauge, 0, rng, second.tool)
		assert(
			second.tool.durabilityMilli == 200 and third.tool.durabilityMilli == 50,
			"each attempt wears the same amount"
		)
		local fourth = Taming.capture(c, third.gauge, 0, rng, third.tool)
		assert(fourth.tool.durabilityMilli == 0 and fourth.retry, "wear clamps at zero")
		local broken = Taming.capture(c, fourth.gauge, 0, rng, fourth.tool)
		assert(not broken.ok and broken.reason == "TOOL_BROKEN" and not broken.fled, "a broken tool cannot capture")
	end,
	["success resets the gauge and certain success always captures"] = function()
		local c = config({ successPermille = 1000 })
		local rng = Rng.new(9)
		for _ = 1, 50 do
			local result = Taming.capture(c, full(c, 0), 0, rng, { durabilityMilli = 1000 })
			assert(result.ok and result.captured and not result.retry and result.gauge.level == 0, "always captured")
		end
		local never = config({ successPermille = 0 })
		for _ = 1, 50 do
			assert(
				not Taming.capture(never, full(never, 0), 0, rng, { durabilityMilli = 1000 }).captured,
				"never captured"
			)
		end
	end,
	["clock boundary: the gauge is full at the last instant and refused one step later"] = function()
		local c = config()
		local gauge = full(c, 0)
		local rng = Rng.new(3)
		assert(Taming.capture(c, gauge, 999, rng, { durabilityMilli = 1000 }).ok, "still full just before the step")
		assert(not Taming.capture(c, gauge, 1000, rng, { durabilityMilli = 1000 }).ok, "refused on the step")
		assert(not pcall(Taming.capture, c, gauge, -1, rng, { durabilityMilli = 1000 }), "negative clock rejected")
		assert(not pcall(Taming.level, c, full(c, 5000), 4000), "clock moving backwards rejected")
	end,
	["QA-TAME-01: 10000 seeded simulations land within one percent of the configured rate"] = function()
		for _, permille in { 250, 400, 500, 750 } do
			local c = config({ successPermille = permille })
			local wins = 0
			for seed = 1, 10000 do
				local result = Taming.capture(c, full(c, 0), 0, Rng.new(seed), { durabilityMilli = 1000 })
				assert(result.ok, "full gauge always rolls")
				if result.captured then
					wins += 1
				end
			end
			local observed = wins / 10000
			assert(math.abs(observed - permille / 1000) <= 0.01, `rate {permille}: observed {observed} outside +-1%`)
		end
	end,
	["QA-TAME-01: one generator drawn 10000 times also matches the rate"] = function()
		local c = config({ successPermille = 350 })
		local rng = Rng.new(2026)
		local wins = 0
		for _ = 1, 10000 do
			if Taming.capture(c, full(c, 0), 0, rng, { durabilityMilli = 1000 }).captured then
				wins += 1
			end
		end
		assert(math.abs(wins / 10000 - 0.35) <= 0.01, `observed {wins / 10000}`)
	end,
	["replay: the same seed reproduces the exact result sequence and uses the capture fork"] = function()
		local c = config()
		local function run(seed: number): string
			local rng = Rng.new(seed)
			local out = {}
			for _ = 1, 200 do
				table.insert(
					out,
					if Taming.capture(c, full(c, 0), 0, rng, { durabilityMilli = 1000 }).captured then "1" else "0"
				)
			end
			return table.concat(out)
		end
		assert(run(77) == run(77), "same seed MATCH")
		assert(run(77) ~= run(78), "different seed diverges")
		local expected = Rng.new(77)
		local roll = expected:fork("capture")
		local first = roll:nextInteger(0, 999) < 400
		local result = Taming.capture(c, full(c, 0), 0, Rng.new(77), { durabilityMilli = 1000 })
		assert(result.captured == first, "first roll is the capture-labelled fork")
		local sibling = Rng.new(77):fork("tame"):nextInteger(0, 999) < 400
		local differs = false
		for seed = 1, 64 do
			local a = Rng.new(seed):fork("capture"):nextInteger(0, 999)
			local b = Rng.new(seed):fork("tame"):nextInteger(0, 999)
			if a ~= b then
				differs = true
			end
		end
		assert(differs and sibling ~= nil, "capture stream is independent of other labels")
	end,
	["entitlements cannot reach a roll: the API accepts none and sequences are identical"] = function()
		local c = config()
		local function run(extra: any): string
			local rng = Rng.new(31337)
			local out = {}
			local held = { durabilityMilli = 100000 }
			local gauge = full(c, 0)
			for _ = 1, 300 do
				local result = (Taming.capture :: any)(c, gauge, 0, rng, held, extra)
				held = result.tool
				gauge = if result.captured then full(c, 0) else result.gauge
				table.insert(out, if result.captured then "1" else "0")
				table.insert(out, tostring(held.durabilityMilli))
			end
			return table.concat(out, ",")
		end
		local none = run(nil)
		local paid = run({ gamePasses = { vip = true }, robux = 9999, entitlement = "premium-tamer" })
		local other = run({ gamePasses = {} })
		assert(none == paid and none == other, "unrelated entitlement tables change nothing")
		assert(not pcall(
			Taming.config,
			{
				gaugeMax = 100,
				fillPerHit = 25,
				decayStepMillis = 1000,
				successPermille = 400,
				toolWearMilli = 1,
				penMillis = 0,
				feedShortenMillis = {},
				entitlement = true,
			} :: any
		), "config rejects an entitlement field")
		assert(not pcall(
			Taming.config,
			{
				gaugeMax = 100,
				fillPerHit = 25,
				decayStepMillis = 1000,
				successPermille = 400,
				toolWearMilli = 1,
				penMillis = 0,
				feedShortenMillis = {},
				robuxBonusPermille = 50,
			} :: any
		), "config rejects a Robux modifier")
		assert(
			not pcall(Taming.capture, c, full(c, 0), 0, Rng.new(1), { durabilityMilli = 10, gamePass = true } :: any),
			"tool rejects extra fields"
		)
	end,
	["feed only shortens pen time deterministically and never below the present"] = function()
		local c = config()
		local pen = Taming.pen(c, 1000)
		assert(pen.readyAt == 601000 and Taming.remainingMillis(pen, 1000) == 600000, "pen timer from the clock")
		local fed = Taming.feed(c, pen, 2000, "berry")
		assert(fed.readyAt == 541000 and pen.readyAt == 601000, "berry removes exactly its time, copy-on-write")
		local again = Taming.feed(c, pen, 2000, "berry")
		assert(again.readyAt == fed.readyAt, "same feed same result")
		local stewed = Taming.feed(c, fed, 2000, "stew")
		assert(stewed.readyAt == 361000, "feeds stack linearly")
		local nearly = Taming.feed(c, { startedAt = 0, readyAt = 10000 }, 9000, "stew")
		assert(nearly.readyAt == 9000 and Taming.isReady(nearly, 9000), "never earlier than now")
		local late = Taming.feed(c, pen, 700000, "stew")
		assert(late.readyAt == pen.readyAt, "a ready animal is unchanged")
		assert(not Taming.isReady(pen, 600999) and Taming.isReady(pen, 601000), "ready exactly at readyAt")
		assert(not pcall(Taming.feed, c, pen, 2000, "gold-bait"), "unknown feed rejected")
	end,
	["feed does not change capture outcomes"] = function()
		local c = config()
		local rng = Rng.new(4)
		local a = Taming.capture(c, full(c, 0), 0, rng, { durabilityMilli = 1000 })
		Taming.feed(c, Taming.pen(c, 0), 0, "stew")
		local rng2 = Rng.new(4)
		local b = Taming.capture(c, full(c, 0), 0, rng2, { durabilityMilli = 1000 })
		assert(a.captured == b.captured, "feeding is a separate path")
	end,
	["configuration is validated and frozen"] = function()
		local ok = config()
		assert(table.isfrozen(ok) and table.isfrozen(ok.feedShortenMillis), "frozen")
		for field, bad in
			{
				gaugeMax = 0,
				fillPerHit = 101,
				decayStepMillis = 0,
				successPermille = 1001,
				toolWearMilli = 0,
				penMillis = -1,
			} :: { [string]: number }
		do
			assert(not pcall(config, { [field] = bad }), field .. " rejected")
		end
		assert(not pcall(config, { successPermille = 0.5 }), "fractional rate rejected")
		assert(not pcall(config, { feedShortenMillis = { berry = 0 } }), "zero shorten rejected")
		assert(
			not pcall(Taming.capture, ok, full(ok, 0), 0, { fork = 1 } :: any, { durabilityMilli = 1 }),
			"bad rng rejected"
		)
		assert(not pcall(Taming.hit, ok, full(ok, 0), 0, 0), "zero hits rejected")
	end,
}
