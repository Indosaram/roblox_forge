--!strict
-- Specs for DeployPlan: create vs update actions, refusal of paid random
-- items, and deterministic asset collection.

local DeployPlan = require("./deployplan")
local Catalog = require("../../../core/infra/monetization/Catalog")
local fs = require("@lune/fs")
local serde = require("@lune/serde")

local function fixtureMonetization(name: string): any
	local game = serde.decode("yaml", fs.readFile("cli/forge/fixtures/catalog-lint/" .. name .. "/game.yml"))
	return game.monetization
end

return {
	["QA-BM-01 the dirty catalog fixture is refused with every ADR-07 rule named"] = function()
		local monetization = fixtureMonetization("dirty")
		local plan = DeployPlan.buildPlan("fixture", "staging", monetization, nil)
		assert(plan == nil, "a dirty catalog must not produce a plan")
		local reason = table.concat(Catalog.lint(monetization), "; ")
		for _, expected in
			{
				"luck-drop-boost: luckyCharm",
				"paid-random: mysteryCrate",
				"luck-drop-boost: harvestBoost",
				"soft-currency-sale: shellPack",
				"subscription-effect: tideMonthly",
			}
		do
			assert(string.find(reason, expected, 1, true) ~= nil, "missing " .. expected .. " in " .. reason)
		end
	end,

	["the lint refuses a plan that passes the paid-random field check"] = function()
		local plan, err = DeployPlan.buildPlan("pack", "staging", {
			products = { { key = "harvestBoost", name = "Harvest Boost", price = 149, dropRate = 2 } },
		}, nil)
		assert(plan == nil, "a drop-rate product must not produce a plan")
		assert(err == "catalog lint: luck-drop-boost: harvestBoost (field dropRate)", "reason: " .. tostring(err))
	end,

	["QA-BM-01 the clean survival catalog fixture plans"] = function()
		local plan, err = DeployPlan.buildPlan("fixture", "staging", fixtureMonetization("clean"), nil)
		assert(err == nil, "clean catalog refused: " .. tostring(err))
		assert(plan ~= nil and #plan.items == 4, "gamepasses and products are planned")
	end,
	["production plans require local approval without claiming external proof"] = function()
		for _, quality in
			{
				{ ok = true, code = "LEGACY_UNASSESSED", errors = {}, releaseApproved = false },
				{ ok = false, code = "INCONCLUSIVE", errors = {}, releaseApproved = false },
				{ ok = false, code = "STALE_BUILD", errors = {}, releaseApproved = true },
			}
		do
			assert(
				DeployPlan.buildPlan("pack", "production", {}, nil, quality) == nil,
				'DeployPlan.buildPlan("pack", "production", {}, nil, quality) == nil'
			)
		end
		assert(
			DeployPlan.buildPlan("pack", "production", {}, nil) == nil,
			'DeployPlan.buildPlan("pack", "production", {}, nil) == nil'
		)
		assert(
			DeployPlan.buildPlan("pack", "unknown", {}, nil) == nil,
			'DeployPlan.buildPlan("pack", "unknown", {}, nil) == nil'
		)
		local plan = assert(DeployPlan.buildPlan("pack", "production", {}, nil, {
			ok = true,
			code = "APPROVED",
			errors = {},
			declaredTier = "release-candidate",
			releaseApproved = true,
		}))
		assert(plan.quality and plan.quality.releaseApproved, "plan.quality and plan.quality.releaseApproved")
		assert(
			not plan.externalReleaseAuthorized and not plan.apiVerified,
			"not plan.externalReleaseAuthorized and not plan.apiVerified"
		)
	end,
	["id 0 plans a create and a set id plans an update"] = function()
		local plan, err = DeployPlan.buildPlan("kaiju-egg-raiders", "staging", {
			gamepasses = {
				{ key = "coins2x", name = "2x Coins", price = 399, id = 0 },
			},
			products = {
				{ key = "kaijuPack", name = "Guaranteed Kaiju Pack (Rare)", price = 99, id = 12345 },
			},
		}, nil)
		assert(err == nil, "unexpected refusal: " .. tostring(err))
		local built = plan :: DeployPlan.Plan
		assert(#built.items == 2, "expected 2 items, got " .. tostring(#built.items))
		assert(built.items[1].section == "gamepass", "first item is a gamepass")
		assert(built.items[1].action == "create", "id 0 should plan a create")
		assert(built.items[1].id == 0, "create keeps id 0")
		assert(built.items[2].section == "product", "second item is a product")
		assert(built.items[2].action == "update", "a set id should plan an update")
		assert(built.items[2].id == 12345, "update carries the existing id")
	end,

	["a missing id is treated as a create"] = function()
		local plan, err = DeployPlan.buildPlan("pack", "staging", {
			gamepasses = {
				{ key = "vip", name = "VIP", price = 100 },
			},
		}, nil)
		assert(err == nil, "unexpected refusal: " .. tostring(err))
		local built = plan :: DeployPlan.Plan
		assert(built.items[1].action == "create", "missing id should plan a create")
		assert(built.items[1].id == 0, "missing id defaults to 0")
	end,

	["an egg kind item is refused as a paid random item"] = function()
		local plan, err = DeployPlan.buildPlan("pack", "staging", {
			products = {
				{ key = "mysteryEgg", name = "Mystery Egg", price = 50, id = 0, kind = "egg" },
			},
		}, nil)
		assert(plan == nil, "a random item must not produce a plan")
		assert(err == "paid random item: mysteryEgg", "reason: " .. tostring(err))
	end,

	["a pool field is refused as a paid random item"] = function()
		local plan, err = DeployPlan.buildPlan("pack", "staging", {
			gamepasses = {
				{ key = "luckyRoll", name = "Lucky Roll", price = 200, id = 7, pool = { "a", "b" } },
			},
		}, nil)
		assert(plan == nil, "a pooled item must not produce a plan")
		assert(err == "paid random item: luckyRoll", "reason: " .. tostring(err))
	end,

	["assets are collected deterministically by group and order"] = function()
		local plan, err = DeployPlan.buildPlan("pack", "staging", {
			gamepasses = {},
			products = {},
		}, {
			thumbnails = {
				{ id = "b", path = "assets/thumbnails/thumb-b.png" },
				{ id = "a", path = "assets/thumbnails/thumb-a.png" },
			},
			icon = {
				{ id = "a", path = "assets/icon/icon-a.png" },
			},
		})
		assert(err == nil, "unexpected refusal: " .. tostring(err))
		local built = plan :: DeployPlan.Plan
		assert(#built.assets == 3, "expected 3 assets, got " .. tostring(#built.assets))
		assert(built.assets[1].group == "icon", "icon sorts before thumbnails")
		assert(built.assets[2].id == "b", "thumbnail order is preserved")
		assert(built.assets[3].id == "a", "thumbnail order is preserved")
	end,

	["render marks every item deterministic and stable"] = function()
		local plan = DeployPlan.buildPlan("pack", "staging", {
			gamepasses = {
				{ key = "coins2x", name = "2x Coins", price = 399, id = 0 },
			},
		}, {
			icon = {
				{ id = "a", path = "assets/icon/icon-a.png" },
			},
		})
		local built = plan :: DeployPlan.Plan
		local text = DeployPlan.render(built)
		assert(
			string.find(text, "| gamepass | create | coins2x | 2x Coins | 399 | 0 | yes |", 1, true) ~= nil,
			"gamepass row should be rendered as a deterministic create"
		)
		assert(
			string.find(text, "| icon | a | assets/icon/icon-a.png |", 1, true) ~= nil,
			"asset row should be rendered"
		)
	end,
}
