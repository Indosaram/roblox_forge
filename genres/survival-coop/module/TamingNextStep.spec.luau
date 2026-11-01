--!strict
-- R09 polish: the empty tamed-animals sheet leads with a next-step card (what to catch, the starter
-- tool with the owned count or the guide that grants it, how) and a "Show me" button that marks the
-- nearest starter creature and walks there. Rendered headless over a fake engine with the real
-- Robango content and strings.csv; a captured pet then lists with its species name and colour chip.
local fs = require("@lune/fs")
-- Untyped requires: lune-side luau-lsp must not type-check the Roblox modules (loaded below).
local Content = (require :: any)("../../../games/robango-island/src/shared/SurvivalContent")
local PackText = (require :: any)("../../../games/robango-island/PackText.fixture")
local TamingPanel = (require :: any)("./TamingPanel")

local function vec(x: number, y: number, z: number): any
	return { X = x, Y = y, Z = z }
end

-- Minimal fake engine: enough Instance/UDim2/Color3/workspace for TamingPanel.factory to render.
local function mount(locale: string, wild: { { id: string, kind: string, at: any, health: number? } }): any
	local nodes: { any } = {}
	local methods: any = {}
	methods.__index = methods
	function methods:IsA(kind)
		return self.ClassName == kind or kind == "GuiObject" and self.ClassName ~= "UIListLayout"
	end
	function methods:Destroy()
		self.Parent = nil
		self.destroyed = true
	end
	function methods:GetChildren()
		local out = {}
		for _, item in nodes do
			if item.Parent == self then
				table.insert(out, item)
			end
		end
		return out
	end
	function methods:FindFirstChild(name)
		for _, item in nodes do
			if item.Parent == self and item.Name == name then
				return item
			end
		end
		return nil
	end
	function methods:WaitForChild(name)
		return self:FindFirstChild(name) or self
	end
	function methods:GetAttribute(name)
		return (self.attributes or {})[name]
	end
	local function signal()
		return {
			Connect = function()
				return { Disconnect = function() end }
			end,
		}
	end
	local function node(class: string?): any
		local item = setmetatable({ ClassName = class or "Frame", Name = class or "Frame" }, methods)
		item.Activated = signal()
		table.insert(nodes, item)
		return item
	end
	local playerGui = node("PlayerGui")
	local character = node("Model")
	local root = node("Part")
	root.Name, root.Parent, root.Position = "HumanoidRootPart", character, vec(0, 0, 0)
	local world = node("Workspace")
	local folder = node("Folder")
	folder.Name, folder.Parent = "ForgeWildlife", world
	for _, row in wild do
		local model = node("Model")
		model.Name, model.Parent = row.id, folder
		model.attributes =
			{ ForgeWildlifeId = row.id, ForgeWildlifeKind = row.kind, ForgeWildlifeHealthMilli = row.health }
		local part = node("Part")
		part.Name, part.Parent, part.Position = "HumanoidRootPart", model, row.at
	end
	local env: any = table.clone(getfenv())
	env.game = {
		GetService = function(_self, name): any
			if name == "Players" then
				return {
					LocalPlayer = {
						Character = character,
						WaitForChild = function()
							return playerGui
						end,
					},
				}
			end
			return { InputBegan = signal() }
		end,
	}
	world.GetServerTimeNow = function()
		return 1000
	end
	env.workspace = world
	env.task = { spawn = function() end, wait = function() end, delay = function() end }
	env.require = function(path: string)
		if path == "./PackLocale" then
			return require("./PackLocale")
		end
		assert(path == "./WildlifeNames", "unexpected require " .. path)
		return (require :: any)("./WildlifeNames")
	end
	env.Instance = { new = node }
	env.Enum = {
		ZIndexBehavior = { Sibling = 1 },
		AutomaticSize = { Y = 1 },
		SortOrder = { LayoutOrder = 2 },
		HighlightDepthMode = { AlwaysOnTop = 1 },
		ScaleType = { Fit = 1 },
	}
	env.UDim2 = { new = function() end, fromOffset = function() end, fromScale = function() end }
	env.UDim = { new = function() end }
	env.Color3 = {
		fromRGB = function(r, g, b)
			return { r = r, g = g, b = b }
		end,
	}
	local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/TamingPanel.luau")))
	setfenv(chunk, env)
	local panel = chunk()
	local listener: any = nil
	local scroll = node("ScrollingFrame")
	local walks: { any } = {}
	local function make(props: any, class: string): any
		local item = node(class)
		item.Text, item.Parent, item.onClick = props.text, props.parent, props.onClick
		return item
	end
	local sheetFrame = node()
	panel.factory({
		locale = locale,
		content = Content,
		names = PackText.names(locale),
		send = function()
			return { ok = true }
		end,
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		walkTo = function(at: any, within: number)
			table.insert(walks, { at = at, within = within })
		end,
		ui = {
			theme = { default = {} },
			components = {
				modalSheet = function()
					return { frame = sheetFrame, close = node(), scroll = scroll }
				end,
				label = function(_theme, props)
					return make(props, "TextLabel")
				end,
				button = function(_theme, props)
					return make(props, "TextButton")
				end,
				progressBar = function()
					return node(), function() end
				end,
			},
		},
	})
	local function find(name: string): any?
		for _, item in nodes do
			if item.Name == name and item.Parent ~= nil and not item.destroyed then
				local parent = item.Parent
				while parent and parent ~= scroll do
					parent = parent.Parent
				end
				if parent == scroll then
					return item
				end
			end
		end
		return nil
	end
	return {
		push = function(snapshot: any, packet: any?)
			listener(snapshot, packet)
		end,
		find = find,
		walks = walks,
		nodes = nodes,
		status = function(): string
			for _, item in nodes do
				if item.Name == "TamingStatus" then
					return item.Text
				end
			end
			return ""
		end,
	}
end

local EMPTY = { taming = { companions = { pets = {}, receipts = {} }, animals = {}, captureTools = 0 } }
local function packet(items: { any }): any
	local bag = { kind = "carried", items = {} }
	for index, item in items do
		bag.items["i" .. index] = item
	end
	return { snapshots = { ["survival-coop"] = { inventory = { carried = bag } } } }
end
local WILD = {
	{ id = "w-boar", kind = "boar", at = vec(3, 0, 0), health = 1000 },
	{ id = "w-dodo-far", kind = "dodo", at = vec(40, 0, 0), health = 45000 },
	{ id = "w-dodo", kind = "dodo", at = vec(0, 0, 12), health = 45000 },
	{ id = "w-dead", kind = "dodo", at = vec(1, 0, 1), health = 0 },
}

return {
	["the empty sheet shows a next-step card naming the nearest starter species, the bola and its count"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local view = mount(locale, WILD)
			view.push(EMPTY, packet({ { catalogId = "capture-bola", quantity = 1, durabilityMilli = 100000 } }))
			local card = assert(view.find("TameNextStep"), "next-step card " .. locale)
			local title = assert(view.find("NextStepTitle"), "title").Text
			assert(
				title == string.format(TamingPanel.text(locale, "tame_next_title"), TamingPanel.species(locale, "dodo")),
				title
			)
			local tool = assert(view.find("NextStepTool"), "tool line").Text
			local bola = PackText.names(locale)["capture-bola"]
			assert(tool == string.format(TamingPanel.text(locale, "tame_next_tool"), bola, 1), tool)
			assert(assert(view.find("NextStepArt"), "tool art").Parent == card, "art inside the card")
			assert(view.find("NextStepSpecies") ~= nil, "species chip")
			assert(view.find("NextStepHow").Text == TamingPanel.text(locale, "tame_next_how"), "how line")
			assert(view.find("CompanionEmpty") ~= nil, "the rule text stays under the card")
			assert(card.LayoutOrder < view.find("CompanionEmpty").LayoutOrder, "card leads the sheet")
			for _, key in { "tame_next_title", "tame_next_tool", "tame_next_go", "tame_next_how" } do
				assert(TamingPanel.text(locale, key) ~= key, "csv row " .. key)
			end
		end
	end,
	["the Show me button marks and walks to the nearest alive starter creature"] = function()
		local view = mount("en-us", WILD)
		view.push(EMPTY, packet({ { catalogId = "capture-bola", quantity = 1, durabilityMilli = 75000 } }))
		local go = assert(view.find("NextStepGo"), "next-step button")
		assert(go.ClassName == "TextButton" and go.Text == "Show me the nearest one", tostring(go.Text))
		assert(type(go.onClick) == "function", "button is wired")
		go.onClick()
		assert(#view.walks == 1, "walked once")
		local at = view.walks[1].at
		assert(at.X == 0 and at.Z == 12, "walks to the nearest alive dodo, not the boar or the dead one")
		local marks = 0
		for _, item in view.nodes do
			if item.Name == "ForgeTameGuide" and not item.destroyed then
				marks += 1
				assert(item.Parent.Name == "w-dodo", "outline on the target creature")
			end
		end
		assert(marks == 1, "one guide outline")
		assert(view.status() == "Dodo marked, 12m away", view.status())
	end,
	["without a bola the card says which guide grants it"] = function()
		for _, locale in { "en-us", "ko-kr" } do
			local view = mount(locale, {})
			view.push(EMPTY, packet({}))
			local tool = assert(view.find("NextStepTool"), "tool line").Text
			local guide = TamingPanel.text(locale, "chr.guide_g02")
			assert(
				string.find(tool, string.format(TamingPanel.text(locale, "tame_next_from_guide"), guide), 1, true),
				tool
			)
			assert(
				string.find(
					tool,
					string.format(TamingPanel.text(locale, "tame_next_tool"), PackText.names(locale)["capture-bola"], 0),
					1,
					true
				),
				tool
			)
			-- No starter creature around: the button says so instead of walking.
			view.find("NextStepGo").onClick()
			assert(#view.walks == 0, "no walk without a target")
			assert(view.status() ~= "", "says none nearby")
		end
		-- Guide already done: point at the recipe instead.
		local step = assert(TamingPanel.nextStep("en-us", Content, PackText.names("en-us"), {
			captureTools = 0,
			character = { definitions = { ["rw.g02.first-axe"] = true } },
		}))
		assert(step.owned == 0 and string.find(step.tool, "Craft one:", 1, true), step.tool)
	end,
	["after a capture the sheet lists the pet with its species name and colour chip, no next-step card"] = function()
		local view = mount("en-us", WILD)
		local state = {
			companions = {
				pets = {
					p1 = { id = "p1", species = "dodo", phase = "Captured", satiety = 50, feeds = 0, readyAt = 0 },
				},
				receipts = {},
			},
			animals = {},
		}
		view.push({ taming = state }, packet({}))
		assert(view.find("TameNextStep") == nil, "no next-step card once a pet is owned")
		local row = assert(view.find("Companion-p1"), "pet row")
		local title = nil
		for _, item in view.nodes do
			if item.Parent == row and item.Name == "CompanionTitle" then
				title = item.Text
			end
		end
		assert(title == "Dodo · Captured", tostring(title))
		assert(view.find("SpeciesChip") ~= nil, "species colour chip")
	end,
}
