--!strict
-- Specs for planner: deterministic concept -> pack generation, the "Steal a"
-- rejection, odds and paid-randomness invariants, procgen consistency with the
-- roster, and the bounded balance search against the pure econsim simulator.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local planner = require("./planner")
local codegen = require("./codegen")
local gameyml = require("./gameyml")
local procgen = require("./procgen")

local CONCEPT = "sky whale egg keepers defend floating islands"
local TEMPLATE_PATH = "genres/collect-raid/econ-template.yml"

local function templatePlan(): any
	local decoded = serde.decode("yaml", fs.readFile(TEMPLATE_PATH))
	return decoded.plan
end

local function assemble(seed: number)
	local plan = templatePlan()
	local roster = planner.buildRoster(CONCEPT, plan, seed)
	local tune = planner.tune(plan, roster)
	local economy = planner.buildEconomy(plan, roster, tune.priceMultiplier, tune.productionMultiplier)
	return plan, roster, tune, economy
end

-- Assembled once; the tuner passes on the first candidate, so this is cheap.
local PLAN, ROSTER, TUNE, ECONOMY = assemble(7)
local TITLE = planner.deriveTitle(CONCEPT)

local function vipStationsSpec(): ()
	local count = PLAN.incubators + 4
	local layout = luau.load(planner.renderWorldLayout(ROSTER, TITLE, { "Red", "Blue" }, "Probe", count), {
		environment = {
			require = function(_path: string)
				return require("../../../genres/collect-raid/module/WorldBuilderMath")
			end,
		},
	})()
	for _, base in layout.layout.bases do
		assert(#base.incubators >= count, "world must include every VIP incubator")
	end
end

-- WorldBuilder places the base platform, the vault crate (10x10) and the shop
-- (6x3) with `Position`, not a rotated `CFrame`, so their footprints are
-- always axis-aligned in world space, regardless of the base's own rotation
-- around the arena. A pedestal is a 9-stud cylinder (radius 4.5). This runs
-- the actual generated layout (not fixed/hand-picked coordinates) for every
-- combination the fix must hold for, including the 3-team layout whose
-- 120/240 degree bases are not axis-aligned ("diagonal") -- the case a plain
-- two-row offset tuned only against 0/90/180/270 degree bases would miss.
local function incubatorGeometrySpec(): ()
	local PEDESTAL_RADIUS = 4.5
	local VAULT_HALF_X, VAULT_HALF_Z = 5, 5
	local SHOP_HALF_X, SHOP_HALF_Z = 3, 1.5

	local function circleRectClear(
		point: { x: number, z: number },
		rectCenter: { x: number, z: number },
		halfX: number,
		halfZ: number,
		radius: number
	): boolean
		local dx = math.max(math.abs(point.x - rectCenter.x) - halfX, 0)
		local dz = math.max(math.abs(point.z - rectCenter.z) - halfZ, 0)
		return math.sqrt(dx * dx + dz * dz) >= radius
	end

	local teamSets = {
		{ "Red", "Blue" },
		{ "Red", "Blue", "Green" },
		{ "Red", "Blue", "Green", "Yellow" },
	}
	for _, teams in teamSets do
		for _, count in { 4, 6, 7 } do
			local layout = luau.load(planner.renderWorldLayout(ROSTER, TITLE, teams, "Probe", count), {
				environment = {
					require = function(_path: string)
						return require("../../../genres/collect-raid/module/WorldBuilderMath")
					end,
				},
			})()
			for _, base in layout.layout.bases do
				local halfX, halfZ = base.size.x / 2, base.size.z / 2
				local label = string.format("%d teams, %d stations, %s", #teams, count, base.team)
				for i, p in base.incubators do
					local withinX = math.abs(p.x - base.center.x) + PEDESTAL_RADIUS <= halfX
					local withinZ = math.abs(p.z - base.center.z) + PEDESTAL_RADIUS <= halfZ
					assert(withinX and withinZ, label .. " incubator " .. tostring(i) .. " overruns the platform")
					assert(
						circleRectClear(p, base.vault, VAULT_HALF_X, VAULT_HALF_Z, PEDESTAL_RADIUS),
						label .. " incubator " .. tostring(i) .. " overlaps the vault crate"
					)
					assert(
						circleRectClear(p, base.shop, SHOP_HALF_X, SHOP_HALF_Z, PEDESTAL_RADIUS),
						label .. " incubator " .. tostring(i) .. " overlaps the shop"
					)
					for j = i + 1, #base.incubators do
						local q = base.incubators[j]
						local dx, dz = p.x - q.x, p.z - q.z
						local d = math.sqrt(dx * dx + dz * dz)
						assert(
							d >= 10,
							label .. " incubators " .. tostring(i) .. " and " .. tostring(j) .. " too close"
						)
					end
				end
			end
		end
	end
end

local function countKeys(value: { [any]: any }): number
	local count = 0
	for _ in pairs(value) do
		count += 1
	end
	return count
end

local function clientParadeSpec(): ()
	for _, creatureCount in { 2, 6, 9 } do
		local roster = table.clone(ROSTER)
		roster.creatures = {}
		for i = 1, creatureCount do
			table.insert(roster.creatures, ROSTER.creatures[(i - 1) % #ROSTER.creatures + 1])
		end
		local layout = luau.load(planner.renderWorldLayout(roster, TITLE, { "Red", "Blue" }, "Probe", 12), {
			environment = {
				require = function(_path: string)
					return require("../../../genres/collect-raid/module/WorldBuilderMath")
				end,
			},
		})()
		local captured: any = nil
		local shared: any = {}
		for _, key in { "Config", "Catalog", "ProcAssets", "CreatureModels", "Fx", "Copy", "AudioConfig", "Remotes" } do
			shared[key] = {}
		end
		shared.Config.creatures = {}
		shared.WorldLayout = layout
		local client = {
			start = function(options: any)
				captured = options
			end,
		}
		local forge = {
			genres = { ["collect-raid"] = { module = { runtime = { Client = client } } } },
			games = { ["x-pack"] = { src = { shared = shared } } },
		}
		luau.load(planner.renderClient("x-pack", "Probe", { "Red", "Blue" }, 12), {
			environment = {
				game = {
					GetService = function(_self: any, _name: string)
						return {
							WaitForChild = function(_storage: any, _child: string)
								return forge
							end,
						}
					end,
				},
				require = function(module: any)
					return module
				end,
			},
		})()
		assert(captured.worldView.incubatorCount == 12, "VIP incubators remain independent of parade slots")
		assert(captured.worldView.slotCount == math.max(3, creatureCount), "client renders every intended parade index")
		for _, base in layout.layout.bases do
			assert(
				captured.worldView.slotCount == #base.parade.positions,
				"client and each team's physical slots agree"
			)
		end
	end
end

return {
	["generated catalog grant contract matches the real runtime grant"] = function()
		local generated = planner.renderCatalog(ECONOMY, ROSTER)
		local runtime = fs.readFile("genres/collect-raid/module/runtime/Loop.luau")
		local function grantContract(source: string): ({ [string]: boolean }, { [string]: string })
			local union = source:match("export type GrantKind = ([^\n]+)")
			assert(union ~= nil, "grant kind union is exported")
			local kinds: { [string]: boolean } = {}
			for kind in union:gmatch('"([^" ]+)"') do
				kinds[kind] = true
			end
			local shape = source:match("export type Grant = {([^}]+)}")
			assert(shape ~= nil, "grant record is exported")
			local fields: { [string]: string } = {}
			for key, value in shape:gmatch("([%w_]+):%s*([^,]+),") do
				fields[key] = assert(value, "grant field has a type")
			end
			return kinds, fields
		end
		local generatedKinds, generatedFields = grantContract(generated)
		local runtimeKinds, runtimeFields = grantContract(runtime)
		assert(not generatedKinds.coins, "legacy mutable catalog maps keep their grant kind union")
		assert(generatedFields.amount == nil, "legacy catalog grant shape stays unchanged")
		for kind in runtimeKinds do
			assert(generatedKinds[kind], "generated grant is missing runtime kind " .. kind)
		end
		for kind in generatedKinds do
			assert(runtimeKinds[kind], "generated grant has unsupported runtime kind " .. kind)
		end
		for key, value in runtimeFields do
			assert(generatedFields[key] == value, "generated grant field differs from runtime: " .. key)
		end
		for key, value in generatedFields do
			assert(runtimeFields[key] == value, "runtime grant field differs from generated: " .. key)
		end
		luau.compile(generated)
		local catalog = luau.load(generated)()
		local Catalog = require("../../../core/infra/monetization/Catalog")
		assert(Catalog.validate(catalog), "generated entries remain valid deterministic products")
	end,
	["generated client consumes actual layout parade slots, not income or incubator caps"] = clientParadeSpec,
	["world layout includes all VIP incubator stations"] = vipStationsSpec,
	["incubator stations stay on the platform and clear of the vault and shop"] = incubatorGeometrySpec,
	["the title derives from concept words"] = function()
		assert(TITLE == "Sky Whale Egg Keepers", "unexpected title: " .. TITLE)
		local words = planner.nameWords(CONCEPT)
		assert(#words >= 2, "the concept should yield name words")
		assert(words[1] == "sky" and words[2] == "whale", "name words must keep concept order")
	end,

	["the 'Steal a' pattern is rejected and transformed"] = function()
		assert(planner.containsStealPattern("Steal a Kaiju Egg"), "the pattern must be detected")
		assert(planner.containsStealPattern("steal the vault"), "the 'steal the' variant must be detected")
		assert(not planner.containsStealPattern("Stealth Ninja"), "stealth is not the forbidden title word")
		assert(planner.deriveTitle("stealth ninja eggs") == "Stealth Ninja Eggs", "valid title retained")
		local title = planner.deriveTitle("steal a kaiju egg")
		assert(not planner.containsStealPattern(title), "a derived title must never carry the pattern")
		assert(title == "Kaiju Egg", "the pattern is dropped, not repeated: " .. title)
	end,

	["the same concept and seed render byte-identical output"] = function()
		local _, rosterA, _, economyA = assemble(7)
		local _, rosterB, _, economyB = assemble(7)
		assert(planner.renderEconYml(economyA) == planner.renderEconYml(economyB), "econ.yml must be stable")
		assert(planner.renderProcgen(rosterA, TITLE) == planner.renderProcgen(rosterB, TITLE), "procgen stable")
		assert(
			planner.renderConfig(rosterA, TITLE) == planner.renderConfig(rosterB, TITLE),
			"Config.luau must be stable"
		)

		local _, rosterC, _, _ = assemble(5)
		assert(
			planner.renderProcgen(rosterA, TITLE) ~= planner.renderProcgen(rosterC, TITLE),
			"a different seed should change the roster"
		)
	end,

	["the roster stays within the genre egg range"] = function()
		local plan = templatePlan()
		for seed = 0, 20 do
			local roster = planner.buildRoster(CONCEPT, plan, seed)
			assert(
				#roster.eggs >= plan.egg_count.min and #roster.eggs <= plan.egg_count.max,
				"egg count out of range at seed " .. tostring(seed)
			)
			assert(#roster.creatures == #roster.eggs * #plan.rarity_tiers, "one creature per tier per egg")
		end
	end,

	["no two roster creatures share body color, archetype, and scale"] = function()
		local plan = templatePlan()
		for seed = 0, 20 do
			local roster = planner.buildRoster(CONCEPT, plan, seed)
			local seen: { [string]: string } = {}
			for _, creature in roster.creatures do
				local triple = table.concat(creature.body, ",")
					.. "|"
					.. creature.archetype
					.. "|"
					.. tostring(creature.scale)
				assert(
					seen[triple] == nil,
					string.format(
						"seed %d: %s and %s share (body, archetype, scale) = %s",
						seed,
						seen[triple] or "",
						creature.id,
						triple
					)
				)
				seen[triple] = creature.id
			end
		end
	end,

	["archetype follows the creature's name noun via the keyword map"] = function()
		local plan = templatePlan()
		local roster = planner.buildRoster(CONCEPT, plan, 7)
		for _, creature in roster.creatures do
			local lowerName = string.lower(creature.displayName)
			for keyword, archetype in plan.archetype_keywords do
				if string.find(lowerName, keyword, 1, true) ~= nil then
					assert(
						creature.archetype == archetype,
						string.format(
							"%s should use archetype %s for keyword %s, got %s",
							creature.id,
							archetype,
							keyword,
							creature.archetype
						)
					)
				end
			end
		end
	end,

	["a thin concept still pads from the template nouns"] = function()
		local plan = templatePlan()
		local roster = planner.buildRoster("dragon", plan, 0)
		assert(#roster.eggs >= 2, "a one-word concept must still produce the minimum eggs")
		assert(#roster.creatures == #roster.eggs * #plan.rarity_tiers, "creature count must match")
	end,

	["every egg pool is a probability distribution summing to 1"] = function()
		for _, egg in ECONOMY.eggs do
			local sum = 0
			for _, entry in egg.pool do
				assert(entry.weight > 0, "pool weights must be positive")
				sum += entry.weight
			end
			assert(math.abs(sum - 1) < 1e-9, string.format("egg %s weights sum to %.9f", egg.id, sum))
		end
		assert(#planner.validate(ECONOMY, TITLE) == 0, "generated plan must satisfy the invariants")
	end,

	["no Robux item is a random roll"] = function()
		for _, item in ECONOMY.monetization.gamepasses do
			assert(item.deterministic, "game pass " .. item.key .. " must be deterministic")
			assert(not item.affectsFreeHatchOnly, "game passes are not hatch boosts")
		end
		for _, item in ECONOMY.monetization.products do
			assert(item.deterministic, "product " .. item.key .. " must be deterministic")
			assert(item.price > 0 and item.price == math.floor(item.price), "prices are whole Robux")
			local lower = string.lower(item.key)
			assert(string.find(lower, "random") == nil and string.find(lower, "loot") == nil, "no random paid key")
		end
		local luck = ECONOMY.monetization.products[#ECONOMY.monetization.products]
		assert(luck.key == "luckBoost" and luck.affectsFreeHatchOnly, "the luck boost only affects free hatches")
	end,

	["egg prices are positive whole coins"] = function()
		for _, egg in ECONOMY.eggs do
			assert(egg.price > 0 and egg.price == math.floor(egg.price), "egg price must be a positive integer")
			assert(egg.hatchSeconds > 0, "hatch time must be positive")
		end
	end,

	["the tuned economy meets every balance target"] = function()
		assert(TUNE.ok, "the tuner must find a passing configuration")
		local targets = TUNE.targets
		assert(targets ~= nil, "a passing tune must carry a target report")
		local report = targets :: planner.TargetReport
		assert(report.firstPurchaseOk, "first purchase target must pass")
		assert(report.day7GrowthOk, "day-7 growth target must pass")
		assert(report.eggSinkOk, "egg sink target must pass")
	end,

	["impossible targets are reported as failures"] = function()
		local plan = templatePlan()
		plan.first_purchase_target_minutes = { 1000, 2000 }
		local fake: any = {
			medianFirstPurchaseMinute = 5,
			dailyInflation = { 10, 40 },
			totalProduced = 100,
			totalSpent = 1,
		}
		local report = planner.evaluateTargets(plan, fake)
		assert(not report.ok, "an unreachable first-purchase window must fail")
		assert(#report.reasons == 3, "every failing target should be named")
	end,

	["the generated game.yml passes the check validator"] = function()
		local text = planner.renderGameYml(PLAN, ECONOMY, TITLE, "plan-demo", "collect-raid")
		local game = serde.decode("yaml", text)
		local result = gameyml.validate(game)
		assert(result.ok, "game.yml must validate: " .. table.concat(result.errors, "; "))
		assert(#game.analytics_events == 12, "the genre ships 12 analytics events")
		assert(game.ratings.paid_random == false, "paid randomness must be declared false")
		assert(game.slug == "plan-demo" and game.genres[1] == "collect-raid", "slug and genre must be set")
	end,

	["the generated econ.yml codegens deterministically"] = function()
		local text = planner.renderEconYml(ECONOMY)
		local generated = codegen.generate(text)
		assert(string.find(generated, "return EconConfig", 1, true) ~= nil, "codegen must emit a module")
		assert(codegen.generate(text) == generated, "codegen must be byte-stable")
	end,

	["procgen.yml matches the roster and fits the poly budget"] = function()
		local text = planner.renderProcgen(ROSTER, TITLE)
		local doc = serde.decode("yaml", text)
		local resolved, errors = procgen.plan(doc, PLAN.poly_budget)
		assert(#errors == 0, "procgen must resolve: " .. table.concat(errors, "; "))
		assert(resolved ~= nil, "resolved specs are required")
		local entries = resolved :: { procgen.Resolved }

		local expected: { [string]: boolean } = {}
		for _, creature in ROSTER.creatures do
			expected[creature.id] = true
		end
		for _, egg in ROSTER.eggs do
			expected[egg.id] = true
		end
		-- Scatter decor the genre WorldDecor runtime looks up by key.
		for _, key in { "decor-rock", "decor-tree", "decor-crystal", "decor-crate" } do
			expected[key] = true
		end
		assert(countKeys(expected) == #entries, "one procgen asset per roster entry plus decor")
		for _, entry in entries do
			assert(expected[entry.key] == true, "unexpected procgen key " .. entry.key)
			assert(entry.triangleCount <= entry.budget, entry.key .. " exceeds its budget")
		end
	end,

	["renderServer emits compilable teamColors keys for non-identifier team names"] = function()
		local teams = { "Red-Team", "1Blue" }
		local source = planner.renderServer("x-pack", "XPack", teams, "XDebug", 4)
		assert(
			string.find(source, '["Red-Team"] = BrickColor.new', 1, true) ~= nil,
			"teamColors must key non-identifier team names with a bracketed string, got:\n" .. source
		)
		local compileOk, compileErr = pcall(luau.compile, source)
		assert(compileOk, "renderServer output must compile for any recordable team name: " .. tostring(compileErr))
		local clientOk, clientErr = pcall(luau.compile, planner.renderClient("x-pack", "XPack", teams, 4))
		assert(clientOk, "renderClient output must compile for any recordable team name: " .. tostring(clientErr))
		local audioOk, audioErr = pcall(luau.compile, planner.renderAudioConfig("XPack", teams))
		assert(audioOk, "AudioConfig must compile: " .. tostring(audioErr))
		local themeOk, themeErr = pcall(luau.compile, planner.renderWorldTheme(ROSTER, "XPack", teams))
		assert(themeOk, "WorldTheme must compile: " .. tostring(themeErr))
	end,

	["renderServer and renderClient agree on incubatorsPerTeam for a 6-creature roster"] = function()
		local teams = { "Red", "Blue" }
		local incubatorsPerTeam = math.max(6, 4)
		assert(incubatorsPerTeam == 6, "a 6-creature roster must raise incubatorsPerTeam above the floor of 4")
		local serverSource = planner.renderServer("x-pack", "XPack", teams, "XDebug", incubatorsPerTeam)
		local clientSource = planner.renderClient("x-pack", "XPack", teams, incubatorsPerTeam)
		assert(
			string.find(serverSource, "incubatorsPerTeam = 6,", 1, true) ~= nil,
			"renderServer must wire incubatorsPerTeam = 6 for a 6-creature roster"
		)
		assert(
			string.find(clientSource, "incubatorCount = 6,", 1, true) ~= nil,
			"renderClient must wire incubatorCount = 6 for a 6-creature roster"
		)
	end,
}
