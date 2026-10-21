--!strict
local Ecology = require("./CombatEcology")
local capture = { basePermille = 650, levelPermille = 10, bonusPermille = 50, minPermille = 200, maxPermille = 900 }
return {
	["capture eligibility consumes nothing until eligible then consumes rope even on failure"] = function()
		local species = { captureClass = "advanced", level = 40 }
		local facts = {
			survival3 = true,
			stunned = true,
			clanResearch = true,
			stronghold = true,
			occupied = 0,
			capacity = 8,
			rope = 1,
			survivalSkill = 40,
			survival6 = false,
		}
		assert(Ecology.captureChance(species, facts, capture) == 650, "authored chance")
		for _, field in { "survival3", "stunned", "clanResearch", "stronghold" } do
			local invalid = table.clone(facts)
			invalid[field] = false
			local result, rope, reason = Ecology.rollCapture(species, invalid, capture, 1)
			assert(result == nil and rope == 1 and reason ~= nil, "eligibility consumes nothing")
		end
		facts.rope = 0
		assert(select(3, Ecology.rollCapture(species, facts, capture, 1)) == "NO_ROPE", "free capture refused")
		facts.rope = 1
		local result, rope = Ecology.rollCapture(species, facts, capture, 42)
		assert(result ~= nil and rope == 0, "eligible attempt spends rope")
		assert(Ecology.rollCapture(species, facts, capture, 42) == result, "seed replay")
	end,
	["carcass reservoir has one public meat allocation and skill gated extraction without duplication"] = function()
		local corpse = Ecology.carcass("corpse", {
			{ item = "meat", quantity = 3, skillNode = "butchering_1" },
			{ item = "bone", quantity = 2, skillNode = "butchering_3" },
		}, { owner = true }, 0, 120000, 600000, false)
		assert(select(3, Ecology.butcher(corpse, "stranger", "r", "meat", {}, 0)) == "PARTY_RESERVED", "snapshot party")
		local nextCorpse, meat = Ecology.butcher(corpse, "owner", "r", "meat", {}, 0)
		corpse = assert(nextCorpse, "butcher candidate")
		assert(meat == 1 and corpse.remaining.meat == 2, "one meat decremented")
		assert(select(2, Ecology.butcher(corpse, "owner", "r", "meat", {}, 0)) == 0, "receipt replay no grant")
		assert(
			select(3, Ecology.butcher(corpse, "stranger", "r2", "meat", {}, 120000)) == "SKILL_GATED",
			"not one meat per player"
		)
		assert(select(3, Ecology.butcher(corpse, "owner", "bone", "bone", {}, 1)) == "SKILL_GATED", "bone skill")
		local extracted, quantity = Ecology.butcher(corpse, "owner", "m2", "meat", { butchering_1 = true }, 1)
		assert(extracted and quantity == 2 and extracted.remaining.meat == 0, "remaining only")
		assert(
			select(3, Ecology.butcher(corpse, "owner", "late", "bone", { butchering_3 = true }, 600000))
				== "CORPSE_EXPIRED",
			"expiry"
		)
	end,
	["one group windup per actor and stale cancellations cannot free a successor"] = function()
		local tokens = assert(Ecology.acquire({}, "actor", "first"))
		assert(select(2, Ecology.acquire(tokens, "actor", "second")) == "GROUP_ATTACK_BUSY", "bounded group attacks")
		tokens = Ecology.release(tokens, "actor", "first")
		tokens = assert(Ecology.acquire(tokens, "actor", "second"))
		assert(Ecology.release(tokens, "actor", "first").actor == "second", "stale cancellation")
	end,
}
