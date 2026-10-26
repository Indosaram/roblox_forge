--!strict
-- p129: the operation sheet at phone and PC sizes with large text. Renders the real
-- OperationPanel.factory on a minimal fake engine with every content operation and every lock
-- line, then checks each label is tall enough for its wrapped text, measured with the
-- SocialSheet width estimate at the 1.2x text scale. A label grows only through AutomaticSize Y.
-- Host-only (luau-lsp lune set): reads the robango-island content; marker: require("@lune/task")
local fs = require("@lune/fs")
local Sheet = require("./SocialSheet")
local HUDModel = require("./SurvivalHUDModel")
local Operation = require("./OperationExtension")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local Settings = require("../../../games/robango-island/src/shared/SettingsModel")
local Fixture = require("../../../games/robango-island/PackText.fixture")

local BODY = 15 -- ExtensionPanels theme textSizes.body
local MIN = 44
-- "" is the open row (no reason).
local REASONS: { string } =
	{ "", "CHARACTER_LEVEL_GATE", "SKILL_GATE", "INSUFFICIENT_ITEMS", "STATION_GATE", "GUIDE_NOT_OPEN" }

local function mount(locale: string): any
	local nodes: { any } = {}
	local function node(class: string, props: any?): any
		local item: any = { ClassName = class, Name = class, AutomaticSize = "None" }
		for key, value in props or {} do
			item[key] = value
		end
		function item.Destroy(self)
			self.Parent = nil
		end
		table.insert(nodes, item)
		return item
	end
	local signal = {
		Connect = function()
			return { Disconnect = function() end }
		end,
	}
	local player: any = {
		WaitForChild = function()
			return node("PlayerGui")
		end,
	}
	local env: any = setmetatable({
		game = {
			GetService = function(_self, name: string)
				return if name == "Players"
					then { LocalPlayer = player }
					else {
						GetTagged = function()
							return {}
						end,
					}
			end,
		},
		Instance = { new = node },
		Enum = { ZIndexBehavior = { Sibling = "Sibling" }, AutomaticSize = { Y = "Y" } },
		UDim2 = {
			new = function(sx: number, ox: number, sy: number, oy: number)
				return { sx = sx, ox = ox, sy = sy, oy = oy }
			end,
		},
		require = function(path: string)
			assert(path == "./PackLocale", path)
			return require("./PackLocale")
		end,
	}, { __index = getfenv() })
	local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/OperationPanel.luau")))
	setfenv(chunk, env)
	local listener: any = nil
	local scroll = node("ScrollingFrame")
	local function control(class: string, props: any): any
		return node(class, { Text = props.text, Size = props.size, TextSize = BODY })
	end
	chunk().factory({
		locale = locale,
		names = Fixture.names(locale),
		send = function()
			return { ok = true }
		end,
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		ui = {
			theme = { default = {} },
			components = {
				modalSheet = function()
					return { frame = {}, scroll = scroll, close = { Activated = signal } }
				end,
				label = function(_theme, props)
					return control("TextLabel", props)
				end,
				button = function(_theme, props)
					return control("TextButton", props)
				end,
			},
		},
	})
	return {
		snapshot = function(operations: any)
			listener({ operations = { operations = operations } })
		end,
		shown = function(): { any }
			local out = {}
			for _, item in nodes do
				if item.Parent == scroll then
					table.insert(out, item)
				end
			end
			return out
		end,
	}
end

-- Lines the wrapped text needs at `width` (each authored line wraps on its own).
local function lines(text: string, size: number, width: number): number
	local count = 0
	for _, line in string.split(text, "\n") do
		count += math.max(1, math.ceil(Sheet.textWidth(line, size) / width))
	end
	return count
end

return {
	["operation rows grow to fit KO and EN 1.2x text at 360x640 and 1280x720, 44 px minimum (p129)"] = function()
		local size = math.floor(BODY * Settings.TEXT_SCALE.large + 0.5)
		local rows = Operation.operations(Content)
		assert(#rows >= 10, "content operations listed: " .. #rows)
		local grew = false
		for _, locale in { "ko-kr", "en-us" } do
			local panel = mount(locale)
			for _, reason in REASONS do
				local operations = {}
				for _, row in rows do
					table.insert(operations, {
						id = row.id,
						station = row.station,
						inputs = row.inputs,
						outputs = row.outputs,
						reason = if reason == "" then nil else reason,
						guide = Operation.guideGate(row),
					})
				end
				panel.snapshot(operations)
				for _, viewport in { { w = 360, h = 640, touch = true }, { w = 1280, h = 720, touch = false } } do
					local _, _, w = HUDModel.contextSheet(viewport.w, viewport.h, viewport.touch)
					local width = Sheet.contentWidth(w)
					for _, item in panel.shown() do
						local minimum = item.Size.oy
						assert(item.Size.sx == 1 and item.Size.ox == 0, item.Name .. " spans the sheet")
						-- The status line is text, not a control: it keeps its authored 32 px.
						local floor = if item.Name == "OperationStatus" then 32 else MIN
						assert(minimum >= floor, item.Name .. " keeps its minimum height: " .. minimum)
						-- A Gotham line box is 1.5x the text size (p105).
						local needed = math.ceil(lines(item.Text, size, width) * size * 1.5)
						local height = if item.AutomaticSize == "Y" then math.max(minimum, needed) else minimum
						grew = grew or needed > minimum
						assert(
							height >= needed,
							string.format(
								"%s %s %dx%d: %d px for %d px of text",
								locale,
								item.Name,
								viewport.w,
								viewport.h,
								height,
								needed
							)
						)
					end
				end
			end
		end
		assert(grew, "some row needs more than 44 px, so the check measures growth")
	end,
	["the operation status line grows for long refusals (p129)"] = function()
		local status: any = nil
		for _, item in mount("ko-kr").shown() do
			status = if item.Name == "OperationStatus" then item else status
		end
		assert(status and status.AutomaticSize == "Y", "status grows with its text")
	end,
}
