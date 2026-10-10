--!strict
-- Specs for the declarative genre spec: schema, cross-references and the
-- derived-scenario validation. No filesystem, no generation, no sleeps.

local genrespec = require("./genrespec")
local qagen = require("./qagen")
local HudText = require("../../../core/ui-kit/genre/HudText")
local HudFit = require("../../../core/ui-kit/genre/HudFit")
local WorldKit = require("../../../core/ui-kit/genre/WorldKit")
local registryLib = require("./genreregistry")

local function runtime(): any
	return {
		api = 1,
		id = "counter",
		configVersion = 1,
		saveVersion = 1,
		actions = {
			{ id = "increment", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
			{ id = "boost", args = {}, origin = "client", rate = { capacity = 5, refillPerSecond = 2 } },
			{ id = "tick", args = {}, origin = "server", rate = { capacity = 5, refillPerSecond = 2 } },
		},
		events = { "OnIncrement" },
		hooks = { "OnIncrement" },
		validateConfig = function()
			return {}
		end,
		validateSave = function()
			return {}
		end,
		create = function()
			return {}
		end,
	}
end

--- A minimal valid spec: one resource, one bound action, one zone with a node,
--- one cue and a golden path that asserts.
local function spec(): any
	return {
		api = 1,
		version = "1.0.0",
		id = "counter",
		runtime = "counter",
		resources = {
			{
				id = "count",
				nameKey = "count_label",
				name = "Count",
				initial = 0,
				hud = { slot = "resource-bar", order = 1 },
			},
		},
		entities = {
			{ id = "tally", kind = "source", nameKey = "tally_label", name = "Tally", configPath = { "target" } },
		},
		actions = {
			{
				action = "counter:increment",
				control = {
					id = "counter:increment",
					labelKey = "increment_label",
					label = "Increment",
					kind = "button",
					args = {},
					ui = { slot = "action-bar", order = 1 },
				},
				preconditions = { { ref = "rate-limited" } },
				effects = { { path = { "count" }, delta = 1 } },
			},
		},
		loop = {
			{
				id = "tally",
				actions = { "counter:increment" },
				on = "OnIncrement",
				goalKey = "loop_tally",
				goal = "Tally one",
			},
		},
		ui = {
			resourceBar = { resources = { "count" }, order = 1 },
			actionButtons = { from = "actions", kinds = { "button", "prompt", "player-button" }, order = 2 },
			objective = { from = "loop", order = 4 },
			notifications = { kinds = { "info", "refuse", "reward" }, order = 5 },
		},
		world = {
			name = "World",
			spawn = { zone = "hub", offset = { 0, 1, 0 } },
			zones = { { id = "hub", kind = "plaza", center = { 0, 0, 0 }, size = { 40, 1, 40 } } },
			nodes = {
				{
					id = "counter-pad",
					zone = "hub",
					kind = "station",
					position = { 0, 1, 4 },
					control = "counter:increment",
				},
			},
		},
		audio = {
			cues = { { key = "counter-increment", kind = "sfx", type = "click", duration = 0.1, seed = 0 } },
			bindings = {
				{ on = "action:counter:increment", cue = "counter-increment" },
				{ on = "event:OnIncrement", cue = "counter-increment", field = "count" },
			},
		},
		economy = { startingBalance = { path = { "target" } }, simulation = { sourceTotal = ">0" } },
		-- Every declared key carries its translation, so a pack generated from this spec
		-- is consistent in either language.
		locale = {
			default = "en",
			strings = {
				count_label = { ko = "개수" },
				tally_label = { ko = "집계" },
				increment_label = { ko = "증가" },
				loop_tally = { ko = "하나 세기" },
				hud_menu = { ko = "메뉴" },
				hud_select_player = { ko = "플레이어를 먼저 선택하세요" },
			},
		},
		qa = {
			name = "golden-path",
			players = { "1" },
			starterState = { count = 0 },
			goldenPath = {
				{ op = "begin_clock" },
				{ op = "join", player = "1" },
				{ op = "dispatch", player = "1", action = "counter:increment", expect = "ok" },
				{ op = "expect_snapshot", player = "1", genre = "counter", field = "count", equals = 1 },
			},
		},
	}
end

local function violations(raw: any): { string }
	return genrespec.validate(raw, runtime(), { id = "counter", path = "genres/absent" })
end

--- Applies one mutation and asserts the validator names it.
local function rejects(mutate: (any) -> (), needle: string): ()
	local raw = spec()
	mutate(raw)
	local errors = violations(raw)
	for _, err in errors do
		if string.find(err, needle, 1, true) ~= nil then
			return
		end
	end
	error("expected a violation containing '" .. needle .. "', got: " .. table.concat(errors, "; "))
end

return {
	["a complete spec validates"] = function()
		assert(#violations(spec()) == 0, table.concat(violations(spec()), "; "))
	end,

	["a draft may defer its golden path but a real spec may not"] = function()
		local raw = spec()
		raw.draft = true
		raw.qa.goldenPath = {}
		assert(#violations(raw) == 0, table.concat(violations(raw), "; "))
		raw.draft = nil
		rejects(function(candidate)
			candidate.qa.goldenPath = {}
		end, "requires at least one step")
	end,

	["every player-facing string is declared display text, not an id"] = function()
		rejects(function(raw)
			raw.resources[1].name = nil
		end, "resources[1].name: expected a display string")
		rejects(function(raw)
			raw.resources[1].name = "count_label"
		end, "resources[1].name: display string shows the raw identifier count_label")
		rejects(function(raw)
			raw.resources[1].name = "count"
		end, "resources[1].name: display string repeats the identifier or locale key")
		rejects(function(raw)
			raw.entities[1].name = nil
		end, "entities[1].name: expected a display string")
		rejects(function(raw)
			raw.actions[1].control.label = "increment_label"
		end, "control.label: display string shows the raw identifier increment_label")
		rejects(function(raw)
			raw.actions[1].control.label = "counter:increment"
		end, "control.label: display string repeats the identifier or locale key")
		rejects(function(raw)
			raw.loop[1].goal = nil
		end, "loop[1].goal: expected a display string")
		rejects(function(raw)
			raw.loop[1].goal = "loop_tally"
		end, "loop[1].goal: display string shows the raw identifier loop_tally")
	end,

	["locale entries pair every declared key with its display text"] = function()
		local entries = genrespec.localeEntries(spec())
		assert(#entries == 6, "expected six locale keys, got " .. tostring(#entries))
		local csv = genrespec.renderLocaleCsv(spec(), { "en-us", "ko-kr" })
		assert(string.find(csv, "Key,Source,Context,en-us,ko-kr", 1, true) ~= nil, "header names the locale columns")
		assert(string.find(csv, "count_label,Count,", 1, true) ~= nil, "the resource key carries its display text")
		assert(
			string.find(csv, "increment_label,Increment,", 1, true) ~= nil,
			"the control key carries its display text"
		)
	end,

	["every declared key carries a translation in both languages"] = function()
		local table_ = genrespec.localeTable(spec())
		assert(table_.count_label.en == "Count", "the source language is the declared display text")
		assert(table_.count_label.ko == "개수", "the translation comes from the spec")
		assert(genrespec.localeDefault(spec()) == "en", "a spec without a default renders the source language")
		local csv = genrespec.renderLocaleCsv(spec(), { "en-us", "ko-kr" })
		assert(string.find(csv, "count_label,Count,", 1, true) ~= nil, "the en column carries the display text")
		assert(string.find(csv, "Count,개수", 1, true) ~= nil, "the ko column carries the translation")
		local strings = genrespec.serializeLocaleStrings(spec())
		local luau = require("@lune/luau")
		local loaded = luau.load(strings)()
		assert(loaded.increment_label.ko == "증가", "the pack's locale table loads with its translations")
	end,

	["a missing translation or an undeclared key is a violation"] = function()
		rejects(function(raw)
			raw.locale.strings.count_label = nil
		end, "locale.strings.count_label: missing the translation of the resource count key")
		rejects(function(raw)
			raw.locale.strings.count_label = { en = "Count" }
		end, "locale.strings.count_label: missing the ko string")
		rejects(function(raw)
			raw.locale.strings.absent_key = { ko = "없음" }
		end, "locale.strings.absent_key: no declared locale key of that name")
		rejects(function(raw)
			raw.locale.default = "fr"
		end, "locale.default: expected one of")
		rejects(function(raw)
			raw.locale = nil
		end, "locale: expected")
	end,

	["one capture shows one language"] = function()
		local raw = spec()
		local plan = HudText.plan(raw, genrespec.controls(raw))
		local strings = genrespec.localeTable(raw)
		assert(#HudText.mixedScript(HudText.displaySet(plan, strings, "en"), "en") == 0, "English is one script")
		assert(#HudText.mixedScript(HudText.displaySet(plan, strings, "ko"), "ko") == 0, "Korean is one script")
		-- A pack half-translated into the language it renders is the defect this catches.
		strings.loop_tally.ko = strings.loop_tally.en
		assert(
			#HudText.mixedScript(HudText.displaySet(plan, strings, "ko"), "ko") == 1,
			"a HUD that mixes scripts is reported"
		)
	end,

	["every registered genre spec keeps its spawn view clear"] = function()
		local registry = assert(registryLib.discover())
		for _, id in registry.order do
			local world = registry.packages[id].spec.world
			if type(world) == "table" then
				local occluders: { string } = {}
				for _, entry in WorldKit.clearanceViolations(world) do
					table.insert(occluders, entry.name)
				end
				assert(#occluders == 0, id .. " spawn view occluded by " .. table.concat(occluders, ", "))
			end
		end
	end,

	["every registered genre's action labels fit the phone action bar"] = function()
		local registry = assert(registryLib.discover())
		for _, id in registry.order do
			local raw = registry.packages[id].spec
			-- Only a kit HUD lays its action row out with HudFit; a genre-owned HUD
			-- places its own controls, so its labels are not measured against it.
			local override = type(raw.overrides) == "table" and type(raw.overrides.client) == "table"
			if not override then
				local strings = genrespec.localeTable(raw)
				local labels: { string } = {}
				for _, control in genrespec.controls(raw) do
					if control.kind ~= "prompt" then
						table.insert(labels, HudText.localized(strings, "en", nil, control.label))
					end
				end
				local errors = HudFit.surfaceViolations(labels)
				assert(#errors == 0, id .. ": " .. table.concat(errors, "; "))
			end
		end
	end,

	["identity, api and runtime must match the package"] = function()
		rejects(function(raw)
			raw.api = 2
		end, "api: unsupported spec api")
		rejects(function(raw)
			raw.id = "other"
		end, "id: must equal the package id")
		rejects(function(raw)
			raw.runtime = "other"
		end, "runtime: must equal RuntimeContract.id")
		rejects(function(raw)
			raw.version = "1.0"
		end, "version: expected major.minor.patch")
		rejects(function(raw)
			raw.nonsense = true
		end, "unknown field nonsense")
	end,

	["actions bind declared client actions through legal controls"] = function()
		rejects(function(raw)
			raw.actions[1].action = "counter:tick"
		end, "control: undeclared client action")
		rejects(function(raw)
			raw.actions[1].action = "counter:missing"
		end, ".action: undeclared runtime action")
		rejects(function(raw)
			raw.actions[1].control.id = "increment"
		end, "control: invalid/duplicate namespaced id")
		rejects(function(raw)
			raw.actions[1].control.args = { 1 }
		end, "control: invalid arity")
		rejects(function(raw)
			raw.actions[1].control.kind = "switch"
		end, "control: invalid kind")
		rejects(function(raw)
			raw.actions[1].control = nil
		end, "every action row binds one player-facing control")
		rejects(function(raw)
			raw.actions[1].preconditions = { { ref = "" } }
		end, "expected { ref = <id> }")
		rejects(function(raw)
			raw.actions[1].effects = { { path = { "count" } } }
		end, "expected { path = [...], delta = <number> }")
	end,

	["ui.actionButtons must render every declared control kind"] = function()
		rejects(function(raw)
			raw.ui.actionButtons.kinds = { "button" }
			raw.actions[1].control.kind = "prompt"
		end, "is not rendered")
		rejects(function(raw)
			raw.ui.resourceBar.resources = {}
		end, "missing declared resource count")
		rejects(function(raw)
			raw.ui.objective.from = "actions"
		end, "ui.objective: expected { from = loop")
	end,

	["the loop names declared actions and runtime events"] = function()
		rejects(function(raw)
			raw.loop[1].actions = { "counter:boost" }
		end, ".actions: undeclared action counter:boost")
		rejects(function(raw)
			raw.loop[1].on = "OnMissing"
		end, ".on: undeclared runtime event OnMissing")
	end,

	["world geometry must be finite and inside its zone"] = function()
		rejects(function(raw)
			raw.world.nodes[1].position = { 0, 1, 90 }
		end, ".position: node is outside its zone")
		rejects(function(raw)
			raw.world.spawn.offset = { 900, 1, 0 }
		end, ".offset: spawn is outside its zone")
		rejects(function(raw)
			raw.world.nodes[1].zone = "absent"
		end, ".zone: undeclared zone absent")
		rejects(function(raw)
			raw.world.nodes[1].control = "counter:boost"
		end, ".control: undeclared control counter:boost")
		rejects(function(raw)
			raw.world.zones[1].size = { 40, 0, 40 }
		end, ".size: expected three positive numbers")
		rejects(function(raw)
			raw.world.zones[1].team = "red"
		end, ".team: only a base zone declares a team")
		rejects(function(raw)
			raw.world.nodes[1].position = { 0, 1, math.huge }
		end, ".position: expected three finite numbers")
	end,

	["audio bindings resolve to declared cues and runtime events"] = function()
		rejects(function(raw)
			raw.audio.bindings[1].cue = "counter-missing"
		end, ".cue: undeclared cue counter-missing")
		rejects(function(raw)
			raw.audio.bindings[1].on = "action:counter:boost"
		end, ".on: undeclared action binding counter:boost")
		rejects(function(raw)
			raw.audio.bindings[2].on = "event:OnMissing"
		end, ".on: undeclared runtime event OnMissing")
		rejects(function(raw)
			raw.audio.bindings[1].on = "count"
		end, "expected 'action:<genre>:<action>' or 'event:<Name>'")
		rejects(function(raw)
			raw.audio.bindings[2].on = "action:counter:increment"
		end, "duplicate binding for action:counter:increment")
		rejects(function(raw)
			raw.audio.cues[1].kind = "noise"
		end, "audio.cues: cue counter-increment has an invalid kind")
	end,

	["the golden path is validated as the scenario it derives"] = function()
		rejects(function(raw)
			raw.qa.goldenPath[3].op = "levitate"
		end, "unknown operation")
		rejects(function(raw)
			raw.qa.goldenPath[3].action = "other:increment"
		end, "action is outside the scenario genre")
		rejects(function(raw)
			raw.qa.goldenPath = { { op = "begin_clock" }, { op = "join", player = "1" } }
		end, "must assert at least once")
		rejects(function(raw)
			raw.qa.goldenPath[4].genre = "Other"
		end, "expected a genre id")
		rejects(function(raw)
			raw.qa.players = {}
		end, "players: expected a nonempty dense list")
	end,

	["a per-mode golden path is validated as the document that mode publishes"] = function()
		local raw = spec()
		raw.qa.crafting = {
			goldenPath = {
				{ op = "begin_clock" },
				{ op = "join", player = "1" },
				{ op = "expect_snapshot", player = "1", genre = "counter", field = "count", equals = 0 },
			},
		}
		assert(#violations(raw) == 0, table.concat(violations(raw), "; "))
		local wave = qagen.derive(raw, { name = "golden-path", genre = "counter", pack = "probe" }, nil)
		assert(#wave.steps == #raw.qa.goldenPath, "no mode selects the shared path")
		local crafting = qagen.derive(raw, { name = "golden-path", genre = "counter", pack = "probe" }, "crafting")
		assert(#crafting.steps == 3, "the crafting mode selects its own path")
		assert(crafting.players[1] == "1", "shared keys are inherited by a mode block")
		rejects(function(candidate)
			candidate.qa.crafting = { goldenPath = {} }
		end, "qa.crafting.goldenPath: a non-draft spec requires at least one step")
	end,

	["overrides must name this genre's own modules and declared actions"] = function()
		local raw = spec()
		raw.overrides = { uiTargets = { ["legacy-button"] = "counter:increment" } }
		assert(#violations(raw) == 0, table.concat(violations(raw), "; "))
		rejects(function(candidate)
			candidate.overrides = { uiTargets = { ["legacy-button"] = "counter:boost" } }
		end, "undeclared action counter:boost")
		rejects(function(candidate)
			candidate.overrides = { client = { module = "genres/other/module/Hud" } }
		end, "must be a module of this genre")
		rejects(function(candidate)
			candidate.overrides = { client = { module = "genres/counter/module/Hud" } }
		end, "module file is missing")
	end,

	["a genre's runtime audio module must equal its spec's audio declaration"] = function()
		-- A pack whose client owns its own transport reads the declaration from the genre
		-- module, while the generated client reads the serialized spec: a drift between the
		-- two would play a cue the spec does not bind, or miss one it does.
		local registry = assert(registryLib.discover())
		local context = { id = "grow-harvest", path = "genres/grow-harvest" }
		local raw = assert(genrespec.load("genres/grow-harvest/genre-spec.yml"))
		local growRuntime = registry.runtimes["grow-harvest"]
		assert(#genrespec.validate(raw, growRuntime, context) == 0, "the shipped module equals the spec")

		local driftedCue = assert(genrespec.load("genres/grow-harvest/genre-spec.yml"))
		driftedCue.audio.cues[1].duration = 0.9
		local cueErrors = genrespec.validate(driftedCue, growRuntime, context)
		assert(
			#cueErrors == 1 and string.find(cueErrors[1], "module/Audio.luau: cues", 1, true) ~= nil,
			"a cue that drifted from the module is a violation: " .. table.concat(cueErrors, "; ")
		)

		local driftedBinding = assert(genrespec.load("genres/grow-harvest/genre-spec.yml"))
		driftedBinding.audio.bindings[1].cue = "grow-harvest-plant"
		local bindingErrors = genrespec.validate(driftedBinding, growRuntime, context)
		assert(
			#bindingErrors == 1 and string.find(bindingErrors[1], "module/Audio.luau: bindings", 1, true) ~= nil,
			"a binding that drifted from the module is a violation: " .. table.concat(bindingErrors, "; ")
		)

		-- A genre without the module is not asked for one: the generated client reads the
		-- declaration out of the serialized spec.
		assert(#violations(spec()) == 0, "a genre with no runtime audio module still validates")
	end,

	["declared controls and HUD aliases are read back in order"] = function()
		local raw = spec()
		assert(#genrespec.controlIds(raw) == 1 and genrespec.controlIds(raw)[1] == "counter:increment", "control id")
		local controls = genrespec.controls(raw)
		assert(#controls == 1 and controls[1].label == "Increment", "control descriptor carries its display label")
		assert(next(genrespec.uiTargets(raw)) == nil, "no aliases without overrides")
		raw.overrides = { uiTargets = { ["legacy-button"] = "counter:increment" } }
		assert(genrespec.uiTargets(raw)["legacy-button"] == "counter:increment", "alias read back")
	end,

	["serialization is byte deterministic and valid Luau"] = function()
		local first = genrespec.serialize(spec())
		local second = genrespec.serialize(spec())
		assert(first == second, "identical specs render identical bytes")
		local world = genrespec.serializeWorld(spec().world)
		assert(string.find(world, "counter-pad", 1, true) ~= nil, "world spec carries its nodes")
		local luau = require("@lune/luau")
		local chunk = luau.load(first)()
		assert(chunk.id == "counter" and chunk.actions[1].control.kind == "button", "rendered spec loads")
	end,
}
