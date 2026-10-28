--!strict
-- QA-PERF-01 startup deferral: on the low render profile the client builds no procedural
-- decor (Studio dev-island meshes) before the first prompt is shown or decorDeferSeconds pass;
-- the high profile builds at once. Role worlds build no client decor at all (asset-audit L2: B1
-- kits and B3 rows dress them server-side); the client only starts the biome-kit LOD watcher on
-- each, never deferred. Loads the client's real decor-gate chunk against fake services.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local RenderBudget = require("./src/shared/RenderBudget")

local SOURCE = "games/robango-island/src/client/RobangoIslandClient.client.luau"

local function signal()
	local handlers = {}
	return {
		handlers = handlers,
		Connect = function(_self, handler)
			table.insert(handlers, handler)
			return {
				Disconnect = function()
					table.remove(handlers, table.find(handlers, handler))
				end,
			}
		end,
		fire = function(...)
			for _, handler in table.clone(handlers) do
				handler(...)
			end
		end,
	}
end

local function roleWorld(): any
	local value: any = { Name = "ForgeRoleWorld", Parent = true }
	function value.FindFirstChild()
		return nil
	end
	-- The biome-kit LOD watcher waits for the kit folder.
	function value.WaitForChild()
		return {}
	end
	return value
end

-- Returns counters and the triggers a test drives: prompt shown, delay expiry, and a
-- role world replicating after start.
local function harness(profile: RenderBudget.Profile)
	local source = fs.readFile(SOURCE)
	local first = assert(string.find(source, "local decorGate = RenderBudget.gate()", 1, true), "decor gate chunk")
	local last = #source
	local shown, childAdded, quality = signal(), signal(), signal()
	local delays: { { seconds: number, callback: () -> () } } = {}
	local counts = { lod = 0, islandProps = 0 }
	local initial = { roleWorld() }
	local env = {
		RenderBudget = RenderBudget,
		BiomeKits = {
			runLod = function()
				counts.lod += 1
			end,
		},
		userSettingsLevel = 0,
		profile = profile,
		renderProfile = function()
			return profile
		end,
		decorProp = function()
			counts.islandProps += 1
			return { Parent = nil }
		end,
		CFrame = { new = function() end },
		game = {
			GetService = function(_, name)
				assert(name == "ProximityPromptService" or name == "UserInputService", "unexpected service " .. name)
				return { PromptShown = shown, TouchEnabled = false }
			end,
		},
		script = { Destroying = signal() },
		userSettings = {
			SavedQualityLevel = "Enum.SavedQualitySetting.Automatic",
			GetPropertyChangedSignal = function()
				return quality
			end,
		},
		workspace = {
			ChildAdded = childAdded,
			GetChildren = function()
				return initial
			end,
			WaitForChild = function()
				return {}
			end,
		},
		task = {
			spawn = function(callback, ...)
				callback(...)
			end,
			delay = function(seconds, callback)
				table.insert(delays, { seconds = seconds, callback = callback })
			end,
		},
	}
	luau.load(string.sub(source, first, last), { environment = env })()
	return counts, shown, delays, childAdded
end

local ISLAND_PROPS_LOW = RenderBudget.profiles.low.meshBuildsMax

return {
	["render_profiles declare decorDeferSeconds: low defers, high builds at once"] = function()
		assert(RenderBudget.profiles.low.decorDeferSeconds > 0, "low defers decor")
		assert(RenderBudget.profiles.high.decorDeferSeconds == 0, "high keeps the immediate build")
	end,
	["gate queues work until opened, then runs it once in order and later work at once"] = function()
		local gate = RenderBudget.gate()
		local order = {}
		gate.after(function()
			table.insert(order, 1)
		end)
		gate.after(function()
			table.insert(order, 2)
		end)
		assert(#order == 0 and not gate.isOpen(), "nothing runs before open")
		gate.open()
		gate.open()
		assert(#order == 2 and order[1] == 1 and order[2] == 2, "queued work runs once, in order")
		gate.after(function()
			table.insert(order, 3)
		end)
		assert(#order == 3, "work queued after open runs immediately")
	end,
	["low profile builds no decor before the first shown prompt"] = function()
		local counts, shown, delays, childAdded = harness(RenderBudget.profiles.low)
		childAdded.fire(roleWorld())
		assert(counts.islandProps == 0, "low built decor before first interaction")
		assert(#delays == 1 and delays[1].seconds == RenderBudget.profiles.low.decorDeferSeconds, "bounded fallback")
		shown.fire()
		assert(counts.islandProps == ISLAND_PROPS_LOW, "dev-island meshes keep the low cap")
		delays[1].callback()
		shown.fire()
		assert(counts.islandProps == ISLAND_PROPS_LOW, "the gate opens once")
	end,
	["low profile still builds after decorDeferSeconds when no prompt shows"] = function()
		local counts, _shown, delays = harness(RenderBudget.profiles.low)
		assert(counts.islandProps == 0, "deferred")
		delays[1].callback()
		assert(counts.islandProps == ISLAND_PROPS_LOW, "fallback timer opens the gate")
	end,
	["high profile builds immediately (PC visuals unchanged)"] = function()
		local counts, _shown, delays = harness(RenderBudget.profiles.high)
		assert(#delays == 0 and counts.islandProps == 5, "high builds every dev-island mesh at once")
	end,
	["role worlds get only the biome-kit LOD watcher, never gated and never client decor"] = function()
		local counts, _shown, _delays, childAdded = harness(RenderBudget.profiles.low)
		assert(counts.lod == 1, "the present role world starts its kit LOD at once: " .. counts.lod)
		childAdded.fire(roleWorld())
		assert(counts.lod == 2, "a later role world starts its kit LOD at once")
		local source = fs.readFile(SOURCE)
		assert(not string.find(source, "dressRoleWorld", 1, true), "no client role-world decor pass")
		assert(not string.find(source, "ForgeProcProps", 1, true), "no ForgeProcProps folder")
	end,
	["the client builds one shared ItemIcons catalog for HUD and every panel"] = function()
		local source = fs.readFile(SOURCE)
		local _, builds = string.gsub(source, "ItemIcons%)%.new%(", "")
		assert(builds == 1, "ItemIcons.new walks the full item/recipe catalog; built " .. builds .. " times")
	end,
}
