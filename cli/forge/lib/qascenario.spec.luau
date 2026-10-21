--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local schema = require("./qascenario")
local function scenario(): any
	return serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/bootstrap-crafting-studio.yml"))
end
return {
	["fixture operations require their declared module metadata"] = function()
		local raw = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/role-routing.yml"))
		raw.name = "new-routing-scenario"
		assert(#schema.validate(raw) == 0, "fixture declaration is independent of scenario name")
		raw.fixtures = {}
		assert(#schema.validate(raw) > 0, "undeclared custom operations rejected")
		raw.fixtures = { "cli/forge/fixtures/role-routing" }
		local module: any = require("../fixtures/role-routing/scenario")
		local handler = module.operations.role_travel
		module.operations.role_travel = nil
		local errors = schema.validate(raw)
		module.operations.role_travel = handler
		assert(
			string.find(table.concat(errors, "; "), "unknown operation role_travel", 1, true),
			"metadata mutation rejected"
		)
		assert(#schema.validate(raw) == 0, "restored declaration accepted")
		raw.steps[2].op = "undeclared_operation"
		assert(string.find(table.concat(schema.validate(raw), "; "), "unknown operation undeclared_operation", 1, true))
	end,
	["touch declares actual modality and rejects keyboard relabeling"] = function()
		local raw = scenario()
		local step: any = {
			op = "touch",
			player = "guest",
			target = "Players.LocalPlayer.PlayerGui.ForgeGatherTouch.Gather",
			nodeId = "berry-bush-01",
			expect = "ok",
			timeout_seconds = 10,
		}
		table.insert(raw.steps, step)
		assert(#schema.validate(raw) == 0, "real touch contract, not execution proof")
		step.key = "E"
		assert(#schema.validate(raw) > 0, "touch cannot inject desktop key")
		step.key = nil
		step.resultAction = "survival-coop:food"
		assert(#schema.validate(raw) > 0, "gather and HUD result channels cannot be conflated")
		step.resultAction = nil
		raw.kind = "native"
		assert(#schema.validate(raw) > 0, "touch requires rendered product")
	end,
	["elevated movement has explicit bounded vertical arrival"] = function()
		local raw = scenario()
		local step = {
			op = "walk_to",
			player = "owner",
			target = "Workspace.Lookout",
			withinStuds = 1,
			verticalToleranceStuds = 3,
			timeout_seconds = 20,
		}
		table.insert(raw.steps, step)
		assert(#schema.validate(raw) == 0, "physical vertical arrival tolerance")
		step.verticalToleranceStuds = 0
		assert(#schema.validate(raw) > 0, "zero tolerance rejected")
		step.verticalToleranceStuds = 9
		assert(#schema.validate(raw) > 0, "unbounded vertical shortcut rejected")
	end,
	["correlated prompt contention rejects ambiguous actors and outcomes"] = function()
		local raw = scenario()
		local step: any = {
			op = "parallel_prompt",
			label = "final-charge",
			timeout_seconds = 15,
			nodeId = "fallen-tree-01",
			target = "Workspace.DevelopmentIsland.fallen-tree-01.ForgeGatherAnchor.ForgeGather",
			key = "E",
			players = { "owner", "guest" },
			expect = { ok = 1, refused = 1 },
			conservation = { catalogId = "wood", quantityGain = 3 },
			refusalReasons = { "STALE_VERSION", "NODE_DEPLETED" },
		}
		table.insert(raw.steps, step)
		assert(#schema.validate(raw) == 0, "correlated two-actor contract")
		table.insert(raw.steps, table.clone(step))
		assert(#schema.validate(raw) > 0, "group identity cannot ambiguously name two races")
		table.remove(raw.steps)
		step.players[2] = "owner"
		assert(#schema.validate(raw) > 0, "duplicate actor rejected")
		step.players[2] = "guest"
		step.expect.ok = 2
		assert(#schema.validate(raw) > 0, "two successes cannot prove final-charge contention")
		step.expect.ok = 1
		step.simultaneousTimestamp = 1
		assert(#schema.validate(raw) > 0, "authored timestamps forbidden")
		step.simultaneousTimestamp = nil
		raw.kind = "native"
		assert(#schema.validate(raw) > 0, "real input required")
	end,
	["refused prompt requires exact machine result reason"] = function()
		local raw = scenario()
		local step: any = {
			op = "activate_prompt",
			player = "owner",
			target = "Workspace.Node.Anchor.ForgeGather",
			nodeId = "node",
			key = "E",
			timeout_seconds = 5,
			expect = "refused",
		}
		table.insert(raw.steps, step)
		assert(#schema.validate(raw) > 0, "missing refusal reason")
		step.reason = "NODE_DEPLETED"
		assert(#schema.validate(raw) == 0, "exact refusal")
		step.expect = "ok"
		assert(#schema.validate(raw) > 0, "refusal is not success")
	end,
	["path failure observations require matched ordered subscriptions"] = function()
		local raw = scenario()
		local begin =
			{ op = "path_begin", player = "owner", label = "hunter-path", target = "Workspace.ForgeWildlife.hunter-01" }
		local finish: any = {
			op = "path_end",
			player = "owner",
			label = "hunter-path",
			target = begin.target,
			timeout_seconds = 20,
			outcome = "recovered",
		}
		table.insert(raw.steps, begin)
		assert(#schema.validate(raw) > 0, "unclosed subscription")
		table.insert(raw.steps, finish)
		assert(#schema.validate(raw) == 0, "bounded read-only path observation")
		finish.player = "guest"
		assert(#schema.validate(raw) > 0, "actor swap rejected")
		finish.player = "owner"
		finish.outcome = "idle"
		assert(#schema.validate(raw) > 0, "idle alone is not consumed failure proof")
		finish.outcome = "refused"
		finish.injectFailure = true
		assert(#schema.validate(raw) > 0, "mutation is not telemetry")
	end,
	["named real-surface scenarios validate with ordered canonical bindings"] = function()
		for _, name in
			{
				"full-coop-rejoin",
				"camera-occlusion",
				"inventory-crafting-ui",
				"wildlife-spatial",
				"asset-showcase",
				"release-first-play",
				"release-rejoin",
			}
		do
			local raw = serde.decode("yaml", fs.readFile("genres/survival-coop/qa-scenarios/" .. name .. ".yml"))
			local errors = schema.validate(raw)
			assert(#errors == 0, name .. ": " .. table.concat(errors, "; "))
			raw.kind = "native"
			assert(#schema.validate(raw) > 0, "real surface cannot become native proof")
		end
	end,
	["input predicates require bounded timeout and known scalar references"] = function()
		local raw = scenario()
		table.insert(raw.steps, {
			op = "wait_for",
			player = "owner",
			timeout_seconds = 5,
			predicate = { source = "snapshot", field = "vitals.clockMillis", at_least = { ref = "absent" } },
		})
		assert(#schema.validate(raw) > 0, "unknown predicate binding refused")
		raw.steps[#raw.steps] =
			{ op = "click", player = "owner", target = "Players.LocalPlayer.PlayerGui.Button", timeout_seconds = 0 }
		assert(#schema.validate(raw) > 0, "zero timeout refused")
	end,
	["device viewport bounds and capture angles are explicit"] = function()
		local raw = scenario()
		table.insert(
			raw.steps,
			{ op = "device", player = "owner", surface = "mobile", width = 390, height = 844, timeout_seconds = 10 }
		)
		assert(#schema.validate(raw) == 0, "supported actual device dimensions")
		raw.steps[#raw.steps].width = 0
		assert(#schema.validate(raw) > 0, "invalid viewport refused")
		raw = scenario()
		table.insert(raw.steps, { op = "capture", target = "angles", angles = 2 })
		assert(#schema.validate(raw) > 0, "unsupported angle count refused")
	end,
	["capture layers accept all, world and ui only"] = function()
		for _, layers in { "all", "world", "ui" } do
			local raw = scenario()
			table.insert(raw.steps, { op = "capture", target = "layered", layers = layers })
			assert(#schema.validate(raw) == 0, "layers " .. layers .. " accepted")
		end
		local raw = scenario()
		table.insert(raw.steps, { op = "capture", target = "layered", layers = "hud" })
		assert(#schema.validate(raw) > 0, "unknown layer refused")
	end,
	["Studio gameplay contract validates while native cannot claim its operations"] = function()
		local raw = scenario()
		assert(#schema.validate(raw) == 0, "Studio bootstrap validates")
		raw.kind = "native"
		assert(#schema.validate(raw) > 0, "native rejects gameplay")
	end,
	["server authority rejects epochs and dynamic bindings reject forward references"] = function()
		local raw = scenario()
		raw.steps[4].sessionEpoch = 0
		assert(#schema.validate(raw) > 0, "server derives epoch")
		raw = scenario()
		raw.steps[13].args = { { ref = "not-bound" } }
		assert(#schema.validate(raw) > 0, "unknown binding is rejected")
	end,
}
