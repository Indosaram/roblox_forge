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
			assert(
				string.find(source, 'GetPropertyChangedSignal("ScreenOrientation")', 1, true),
				role .. ": a later change is put back"
			)
		end
	end,
	["the boot pin runs and restores landscape after a change"] = function()
		-- Run the pin block from the real boot script against a stand-in PlayerGui.
		local source = fs.readFile(PACK .. "/src/first/RobangoBoot.client.luau")
		local from = assert(string.find(source, "local LANDSCAPE =", 1, true))
		local to = assert(string.find(source, "\nend)\n", from, true)) + 5
		local listeners: { () -> () } = {}
		local gui: any = {
			ScreenOrientation = "Portrait",
			GetPropertyChangedSignal = function(_, name)
				assert(name == "ScreenOrientation", name)
				return {
					Connect = function(_, fn)
						table.insert(listeners, fn)
					end,
				}
			end,
		}
		local player = {
			WaitForChild = function(_, name)
				assert(name == "PlayerGui", name)
				return gui
			end,
		}
		local Enum = { ScreenOrientation = { LandscapeSensor = "LandscapeSensor", Portrait = "Portrait" } }
		require("@lune/luau").load(string.sub(source, from, to), {
			environment = { player = player, Enum = Enum },
		})()
		assert(gui.ScreenOrientation == "LandscapeSensor", "pinned on join")
		assert(#listeners == 1, "watches the property")
		gui.ScreenOrientation = "Portrait"
		listeners[1]()
		assert(gui.ScreenOrientation == "LandscapeSensor", "a portrait change is put back")
	end,
}
