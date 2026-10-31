--!strict
-- p134 v50 (SM-N981N): the onboarding place ran in portrait (the Roblox activity requested
-- SENSOR_PORTRAIT) while town ran landscape on the same app build. Every role place publishes the
-- same build (forge deploy --all-roles: one artifact, only ServerStorage.ForgePlaceRoles added), so
-- this inspects the built place once per Topology role, after the same per-role injection deploy
-- does, and checks that each ships landscape: StarterGui.ScreenOrientation = LandscapeSensor, no
-- script anywhere in the place sets a non-landscape orientation, and the ReplicatedFirst boot
-- script pins LandscapeSensor on the live PlayerGui before the first frame and keeps it there.
local fs = require("@lune/fs")
local roblox: any = require("@lune/roblox")
local serde = require("@lune/serde")
local run = require("../../cli/forge/lib/run")
local Topology = require("../../core/domain/island/Topology")

local PACK = "games/robango-island"
local OUT = "build/robango-orientation.rbxl"

local ALLOWED = { LandscapeSensor = true, LandscapeLeft = true, LandscapeRight = true }

local function scripts(root: any): { any }
	local out = {}
	for _, item in root:GetDescendants() do
		if item:IsA("LuaSourceContainer") then
			table.insert(out, item)
		end
	end
	return out
end

local function built(): string
	local result = run.exec("rojo", { "build", PACK .. "/default.project.json", "-o", OUT })
	assert(result.ok, "rojo build failed: " .. result.stdout .. result.stderr)
	return fs.readFile(OUT)
end

return {
	["every role place ships landscape and the boot script pins it before the first frame"] = function()
		local bytes = built()
		local roles: { string } = {}
		for role in Topology.ROLES do
			table.insert(roles, role)
		end
		table.sort(roles)
		assert(table.find(roles, "onboarding") and table.find(roles, "town"), "both v50 roles are checked")
		for _, role in roles do
			-- deploy.luau: the role map is added to ServerStorage, nothing else changes per role.
			local place = roblox.deserializePlace(bytes)
			local storage = place:FindFirstChild("ServerStorage")
			if not storage then
				storage = roblox.Instance.new("ServerStorage")
				storage.Parent = place
			end
			local config = roblox.Instance.new("StringValue")
			config.Name, config.Value = "ForgePlaceRoles", serde.encode("json", { [role] = 1 })
			config.Parent = storage
			place = roblox.deserializePlace(roblox.serializePlace(place))
			local starter = place:FindFirstChildOfClass("StarterGui")
			assert(starter, role .. ": StarterGui exists")
			assert(
				starter.ScreenOrientation == roblox.Enum.ScreenOrientation.LandscapeSensor,
				role .. ": StarterGui.ScreenOrientation is " .. tostring(starter.ScreenOrientation)
			)
			for _, item in scripts(place) do
				local source: string = item.Source
				for name in string.gmatch(source, "Enum%.ScreenOrientation%.(%a+)") do
					assert(ALLOWED[name], role .. ": " .. item:GetFullName() .. " uses ScreenOrientation." .. name)
				end
			end
			local first = place:FindFirstChildOfClass("ReplicatedFirst")
			local server = place:FindFirstChildOfClass("ServerScriptService")
			local main = server and server:FindFirstChild("RobangoIslandServer", true)
			assert(main and main:IsA("Script"), role .. ": the server script ships")
			local serverSource: string = main.Source
			local set = string.find(
				serverSource,
				'game:GetService("StarterGui").ScreenOrientation = Enum.ScreenOrientation.LandscapeSensor',
				1,
				true
			)
			assert(set, role .. ": the server sets StarterGui landscape")
			local yields = string.find(serverSource, "WaitForChild(", 1, true)
			assert(not yields or set < yields, role .. ": the server sets it before any yield")
			local boot = first and first:FindFirstChild("RobangoBoot")
			assert(boot and boot:IsA("LocalScript"), role .. ": the ReplicatedFirst boot script ships")
			local source: string = boot.Source
			local pin = string.find(source, "playerGui.ScreenOrientation = LANDSCAPE", 1, true)
			assert(pin, role .. ": boot pins PlayerGui.ScreenOrientation")
			assert(
				string.find(source, "local LANDSCAPE = Enum.ScreenOrientation.LandscapeSensor", 1, true),
				role .. ": the pinned orientation is LandscapeSensor"
			)
			local drawn = assert(string.find(source, "gui.Parent = playerGui", 1, true), "title parented")
			assert(pin < drawn, role .. ": orientation is pinned before the title is drawn")
			-- p134 v64: a require above the pin left the phone in portrait on 3 cold starts.
			local firstRequire = string.find(source, "require(", 1, true)
			assert(not firstRequire or pin < firstRequire, role .. ": orientation is pinned before any require")
			assert(
				string.find(source, 'GetPropertyChangedSignal("ScreenOrientation")', 1, true),
				role .. ": a later change is put back"
			)
		end
	end,
	["the boot pin restores landscape and re-requests it when a cold start stays portrait"] = function()
		-- p134 v66: PlayerGui starts at StarterGui's LandscapeSensor, so re-assigning it is no change
		-- and the Android shell, left in SENSOR_PORTRAIT when its own load hook did not run, never
		-- hears a landscape request. The pin must send a real orientation change after load while
		-- a touch viewport is still portrait. Run the pin block from the real boot script against
		-- stand-ins that, like the engine, fire the property signal only on a real change.
		local source = fs.readFile(PACK .. "/src/first/RobangoBoot.client.luau")
		local from = assert(string.find(source, "local LANDSCAPE =", 1, true))
		local to = assert(string.find(source, "local Flow = require(", from, true)) - 1
		local listeners: { () -> () } = {}
		local changes: { string } = {}
		local state = { ScreenOrientation = "LandscapeSensor" }
		local gui: any = setmetatable({
			GetPropertyChangedSignal = function(_, name)
				assert(name == "ScreenOrientation", name)
				return {
					Connect = function(_, fn)
						table.insert(listeners, fn)
					end,
				}
			end,
		}, {
			__index = state,
			__newindex = function(_, key, value)
				assert(key == "ScreenOrientation", key)
				if state.ScreenOrientation ~= value then
					state.ScreenOrientation = value
					table.insert(changes, value)
					for _, fn in table.clone(listeners) do
						fn()
					end
				end
			end,
		})
		local player = {
			WaitForChild = function(_, name)
				assert(name == "PlayerGui", name)
				return gui
			end,
		}
		local now, timers = 0, {} :: { { at: number, fn: () -> () } }
		local task = {
			delay = function(seconds: number, fn: () -> ())
				table.insert(timers, { at = now + seconds, fn = fn })
			end,
		}
		local function advance(seconds: number)
			local stop = now + seconds
			while true do
				table.sort(timers, function(a, b)
					return a.at < b.at
				end)
				local nextTimer = timers[1]
				if not nextTimer or nextTimer.at > stop then
					break
				end
				table.remove(timers, 1)
				now = nextTimer.at
				nextTimer.fn()
			end
			now = stop
		end
		local viewport = { X = 1080, Y = 2400 }
		local loaded: (() -> ())? = nil
		local game = {
			IsLoaded = function()
				return false
			end,
			Loaded = {
				Once = function(_, fn)
					loaded = fn
				end,
			},
			GetService = function(_, name)
				assert(name == "UserInputService", name)
				return { TouchEnabled = true }
			end,
		}
		local Enum = {
			ScreenOrientation = {
				LandscapeSensor = "LandscapeSensor",
				LandscapeLeft = "LandscapeLeft",
				Portrait = "Portrait",
			},
		}
		require("@lune/luau").load(string.sub(source, from, to), {
			environment = {
				player = player,
				Enum = Enum,
				game = game,
				task = task,
				workspace = { CurrentCamera = { ViewportSize = viewport } },
			},
		})()
		assert(gui.ScreenOrientation == "LandscapeSensor", "pinned on join")
		assert(#listeners == 1, "watches the property")
		gui.ScreenOrientation = "Portrait"
		assert(gui.ScreenOrientation == "LandscapeSensor", "a portrait change is put back")
		table.clear(changes)
		assert(loaded, "waits for game.Loaded");
		(loaded :: () -> ())()
		advance(5)
		assert(#changes > 0, "a portrait viewport after load sends a real orientation change to the shell")
		assert(gui.ScreenOrientation == "LandscapeSensor", "ends on LandscapeSensor")
		for _, value in changes do
			assert(value ~= "Portrait", "never requests portrait")
		end
		-- Once the shell has rotated, the pin stays quiet.
		viewport.X, viewport.Y = 2400, 1080
		table.clear(changes)
		advance(30)
		assert(#changes == 0, "no kick while the viewport is landscape")
		-- Bounded: a device that cannot rotate is not kicked forever.
		viewport.X, viewport.Y = 1080, 2400
		advance(600)
		assert(#changes <= 20, "kicks are capped, got " .. #changes)
	end,
}
