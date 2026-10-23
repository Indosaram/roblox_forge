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
	local head: any = { plates = {} }
	function head.IsA(_, class)
		return class == "BasePart"
	end
	function head.FindFirstChild()
		return nil
	end
	self.head = head
	function self.FindFirstChild(_, child)
		if child == "Head" then
			return head
		end
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

local function folder(name: string, children: { any }): any
	local value: any = { Name = name, DescendantAdded = signal(), DescendantRemoving = signal() }
	function value.GetDescendants()
		return children
	end
	function value.GetChildren()
		return children
	end
	return value
end

-- Loads the client's startCreatureAnimation against fake workspace folders present at start.
local function harness(folders: { any }, profile: any?): (any, any, any)
	local source = fs.readFile(SOURCE)
	local first = assert(string.find(source, "local function startCreatureAnimation", 1, true))
	local last = assert(string.find(source, "local creatureAnimation = startCreatureAnimation", 1, true))
	local renderStepped, descendantAdded = signal(), signal()
	local start = luau.load(string.sub(source, first, last - 1) .. "return startCreatureAnimation", {
		environment = {
			game = {
				GetService = function()
					return { RenderStepped = renderStepped }
				end,
			},
			workspace = {
				GetChildren = function()
					return folders
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
			locale = "ko-kr",
			TamingText = {
				species = function(locale, species)
					return locale .. ":" .. species
				end,
			},
			Instance = {
				new = function(class)
					return setmetatable({ ClassName = class }, {
						__newindex = function(item, key, value)
							rawset(item, key, value)
							if key == "Parent" and type(value) == "table" and value.plates then
								table.insert(value.plates, item)
							end
						end,
					})
				end,
			},
			UDim2 = { fromOffset = function() end, fromScale = function() end },
			Vector3 = { new = function() end },
			Color3 = { fromRGB = function() end },
			Enum = { Font = {} },
			profile = profile or RenderBudget.profiles.high,
			CreaturePose = {
				sample = function(_clock, _state, _speed, _mounted, dt)
					return "idle", dt
				end,
			},
		},
	})()
	return start, renderStepped, descendantAdded
end

return {
	["creature animation poses only Species rigs, never player-like characters"] = function()
		local player = model("Player1", {})
		local creature = model("Grazer1", { Species = "triceratops" })
		local start, renderStepped, descendantAdded = harness({ folder("Wildlife", { player, creature }) })
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
		assert(#creature.head.plates == 1, "one overhead nameplate on the creature")
		local label = creature.head.plates[1] :: any
		assert(label.Name == "ForgeNameplate" and label.MaxDistance == 40, "close-range nameplate")
		assert(#player.head.plates == 0 and #npc.head.plates == 0, "players and NPCs get no creature nameplate")
	end,
	["decorative role-world fauna is registered and grazes on its seeded phase"] = function()
		local grazer = model("ArrivalGrazer1", {
			Species = "triceratops",
			ForgeDecorFauna = true,
			ForgeGrazePhase = 0.25,
			ForgeGrazePeriod = 8,
		})
		local start, renderStepped = harness({ folder("ForgeRoleWorld", { grazer }) })
		local calls = {}
		start(function(target, state, elapsed)
			table.insert(calls, { target = target, state = state, elapsed = elapsed })
		end)
		for _, handler in renderStepped.handlers do
			handler(0.5)
		end
		assert(#calls == 1 and calls[1].target == grazer, "role-world fauna present at start is posed")
		assert(calls[1].state == "graze", "decorative fauna uses the graze idle")
		assert(math.abs(calls[1].elapsed - (0.5 + 0.25 * 8)) < 1e-9, "clock offset by the seeded phase")
		assert(#grazer.head.plates == 0, "a decorative silhouette gets no species nameplate")
	end,
	["the low profile holds decorative fauna still and still poses live wildlife"] = function()
		local grazer = model("ArrivalGrazer1", {
			Species = "triceratops",
			ForgeDecorFauna = true,
			ForgeGrazePhase = 0.25,
			ForgeGrazePeriod = 8,
		})
		local creature = model("Dodo1", { Species = "dodo" })
		local start, renderStepped = harness(
			{ folder("ForgeRoleWorld", { grazer }), folder("Wildlife", { creature }) },
			RenderBudget.profiles.low
		)
		local posed = {}
		start(function(target)
			posed[target] = (posed[target] or 0) + 1
		end)
		for _ = 1, 3 do
			for _, handler in renderStepped.handlers do
				handler(1 / 60)
			end
		end
		assert(posed[grazer] == nil, "low profile spends no per-frame pose on decorative fauna")
		assert(posed[creature] == 3, "live wildlife is still posed every frame")
		assert(RenderBudget.profiles.high.decorFaunaPose, "high keeps the graze idle")
	end,
}
