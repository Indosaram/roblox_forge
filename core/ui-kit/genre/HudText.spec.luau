--!strict
-- Specs for HudText: the identifier patterns, the rendered shapes, and the plan
-- violations that make `forge sweep`'s hud check fail on a raw spec id.

local HudText = require("./HudText")

local function plan(spec: any, controls: { any }): any
	return HudText.plan(spec, controls)
end

return {
	["isIdentifier accepts raw spec ids and rejects player copy"] = function()
		for _, id in { "coin_label", "harvest_crop", "loop_buy", "buy-seed", "rpg-progression" } do
			assert(HudText.isIdentifier(id), "expected an identifier: " .. id)
		end
		for _, text in { "Coins", "Join Queue", "Buy a seed", "Sell-held", "loop", "1000", "Coins 9" } do
			assert(not HudText.isIdentifier(text), "expected display copy: " .. text)
		end
	end,

	["resource renders the display string with the shared number format"] = function()
		assert(HudText.resource("Coins", 9) == "Coins  9", "small value")
		assert(HudText.resource("Coins", 1200) == "Coins  1.2K", "large value uses the shared format")
		assert(HudText.resource("Rating", 1000) == "Rating  1K", "rating")
	end,

	["objective renders the goal with its stage position"] = function()
		assert(HudText.objective("Buy a seed", 1, 4) == "Buy a seed  (1/4)", "first stage")
		assert(HudText.objective("Sell the crop", 4, 4) == "Sell the crop  (4/4)", "last stage")
	end,

	["a plan built from display strings has no violations"] = function()
		local spec = {
			resources = { { id = "coins", nameKey = "coin_label", name = "Coins", initial = 100 } },
			loop = { { id = "buy", goalKey = "loop_buy", goal = "Buy a seed" } },
		}
		local controls =
			{ { id = "grow-harvest:harvest", action = "grow-harvest:harvest", label = "Harvest", kind = "button" } }
		local errors = HudText.violations(plan(spec, controls))
		assert(#errors == 0, table.concat(errors, "; "))
	end,

	["a plan that carries locale keys as labels is reported"] = function()
		local spec = {
			resources = { { id = "coins", nameKey = "coin_label", name = "coin_label", initial = 9 } },
			loop = { { id = "buy", goalKey = "loop_buy", goal = "loop_buy" } },
		}
		local controls = {
			{ id = "grow-harvest:harvest", action = "grow-harvest:harvest", label = "harvest_crop", kind = "button" },
		}
		local errors = HudText.violations(plan(spec, controls))
		assert(
			#errors == 3,
			"expected three violations, got " .. tostring(#errors) .. ": " .. table.concat(errors, "; ")
		)
		for _, expected in { "resource coins", "control grow-harvest:harvest", "objective buy" } do
			local found = false
			for _, error in errors do
				if string.find(error, expected, 1, true) ~= nil then
					found = true
				end
			end
			assert(found, "missing violation for " .. expected)
		end
	end,

	["a display string that repeats its own id or key is reported"] = function()
		local spec = { resources = { { id = "coins", nameKey = "coins", name = "coins" } } }
		local errors = HudText.violations(plan(spec, {}))
		assert(#errors == 1, table.concat(errors, "; "))
	end,

	["a missing or untrimmed display string is reported"] = function()
		local spec = { resources = { { id = "coins", nameKey = "coin_label" } } }
		local errors = HudText.violations(plan(spec, {}))
		assert(
			#errors == 1 and string.find(errors[1], "expected a display string", 1, true) ~= nil,
			table.concat(errors, "; ")
		)
		local untrimmed =
			HudText.violations(plan({ resources = { { id = "coins", nameKey = "coin_label", name = " Coins" } } }, {}))
		assert(
			#untrimmed == 1 and string.find(untrimmed[1], "whitespace", 1, true) ~= nil,
			table.concat(untrimmed, "; ")
		)
	end,

	["assertVisible refuses an identifier and passes real copy"] = function()
		local ok = pcall(HudText.assertVisible, "Coins  9")
		assert(ok, "display copy must pass")
		local refused = pcall(HudText.assertVisible, "coin_label  9")
		assert(not refused, "an identifier must be refused")
	end,
}
