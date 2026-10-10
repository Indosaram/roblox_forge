--!strict
-- Specs for the text-scale contract: a label that scales must be capped by a
-- UITextSizeConstraint, and the modules that actually render the HUD must pass
-- the same check the sweep runs.

local fs = require("@lune/fs")

local HudScale = require("./HudScale")

return {
	["a scaled label with no constraint is reported"] = function()
		local source = 'local label = Instance.new("TextLabel")\nlabel.TextScaled = true\n'
		local errors = HudScale.violations(source, "sheet.luau")
		assert(#errors == 1, "exactly one violation: " .. table.concat(errors, "; "))
		assert(string.find(errors[1], "sheet.luau", 1, true) ~= nil, "the module is named")
		assert(string.find(errors[1], "MaxTextSize", 1, true) ~= nil, "the missing cap is named")
	end,

	["a scaled label that carries a MaxTextSize passes"] = function()
		local source = table.concat({
			'local label = Instance.new("TextLabel")',
			"label.TextScaled = true",
			'local fit = Instance.new("UITextSizeConstraint")',
			"fit.MinTextSize, fit.MaxTextSize = 10, 15",
			"fit.Parent = label",
		}, "\n")
		assert(#HudScale.violations(source, "sheet.luau") == 0, "a constrained scaled label passes")
	end,

	["a module that never scales text is not asked for a constraint"] = function()
		assert(#HudScale.violations("local x = 1\n", "plain.luau") == 0, "no scaling, no constraint required")
	end,

	["the shared Components factory caps the labels it scales"] = function()
		local source = fs.readFile("core/ui-kit/Components.luau")
		assert(HudScale.scales(source), "Components scales its icon button's text label")
		assert(#HudScale.violations(source, "core/ui-kit/Components.luau") == 0, "and caps it")
	end,

	["the kit HUD and both genre HUDs pass the scale gate"] = function()
		local sources = {
			{ label = "core/ui-kit/genre/HudKit.luau", source = fs.readFile("core/ui-kit/genre/HudKit.luau") },
			{
				label = "genres/survival-coop/module/SurvivalHUD.luau",
				source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau"),
			},
			{
				label = "genres/collect-raid/module/runtime/Hud.luau",
				source = fs.readFile("genres/collect-raid/module/runtime/Hud.luau"),
			},
		}
		local errors = HudScale.sourcesViolations(sources)
		assert(#errors == 0, "no unconstrained scaled label: " .. table.concat(errors, "; "))
	end,
}
