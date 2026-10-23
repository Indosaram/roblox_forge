--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local SOURCE = "games/robango-island/src/client/RobangoIslandClient.client.luau"

local function signal()
	local handlers = {}
	return {
		handlers = handlers,
		Connect = function(_self, handler)
			table.insert(handlers, handler)
			return { Disconnect = function() end }
		end,
	}
end

local RenderBudget = (require :: any)("../shared/RenderBudget")

local function model(name: string, attributes: { [string]: any })
	local root = { Position = { X = 0, Y = 0, Z = 0 }, AssemblyLinearVelocity = { Magnitude = 0 } }
	local self: any = { Name = name, PrimaryPart = root }
	function self.IsA(_, class)
		return class == "Model"
	end
	function self.FindFirstChild(_, child)
		return if child == "Torso" or child == "HumanoidRootPart" then root else nil
	end
	function self.GetAttribute(_, key)
		return attributes[key]
	end
	function self.IsDescendantOf()
		return true
	end
	function self.FindFirstChildOfClass()
		return nil
	end
	return self
end

return {
	["creature animation poses only Species rigs, never player-like characters"] = function()
		local source = fs.readFile(SOURCE)
		local first = assert(string.find(source, "local function startCreatureAnimation", 1, true))
		local last = assert(string.find(source, "local creatureAnimation = startCreatureAnimation", 1, true))
		local renderStepped, descendantAdded = signal(), signal()
		local player = model("Player1", {})
		local creature = model("ArrivalGrazer1", { Species = "triceratops" })
		local wildlife: any = { Name = "Wildlife", DescendantAdded = signal(), DescendantRemoving = signal() }
		function wildlife.GetDescendants()
			return { player, creature }
		end
		local start = luau.load(string.sub(source, first, last - 1) .. "return startCreatureAnimation", {
			environment = {
				game = {
					GetService = function()
						return { RenderStepped = renderStepped }
					end,
				},
				workspace = {
					GetChildren = function()
						return { wildlife }
					end,
					CurrentCamera = {
						CFrame = {
							Position = setmetatable({}, {
								__sub = function()
									return { Magnitude = 0 }
								end,
							}),
						},
					},
					ChildAdded = signal(),
					DescendantAdded = descendantAdded,
				},
				-- Upvalues the client chunk defines before this function: the render profile
				-- (high keeps every pose) and a camera at the creature.
				RenderBudget = RenderBudget,
				profile = RenderBudget.profiles.high,
				CreaturePose = {
					sample = function()
						return "idle", 0
					end,
				},
			},
		})()
		local posed = {}
		start(function(target)
			posed[target] = true
		end)
		local npc = model("Villager", {})
		for _, handler in descendantAdded.handlers do
			handler(npc)
			handler(player)
		end
		for _, handler in renderStepped.handlers do
			handler(1 / 60)
		end
		assert(posed[creature], "rig with Species is posed")
		assert(not posed[player] and not posed[npc], "Torso+HumanoidRootPart without Species is never posed")
	end,
}
