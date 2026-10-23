--!strict
-- p56 Studio journey (p58): the 1280 landscape objective wraps to its menu path, a camp donation
-- that finishes a guide shows both lines, and the guide tile is the first menu tile.
local fs = require("@lune/fs")
local HUDModel = require("../../genres/survival-coop/module/SurvivalHUDModel")
local CampModel = require("../../genres/survival-coop/module/CampPanelModel")
local Text = require("../../genres/survival-coop/module/CharacterText")

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

-- Loads the shipped CampPanel on fake instances; `send` runs the panel's snapshot listener first,
-- as the server's ForgeState push reaches the client before the ForgeAction invoke returns.
local function camp(sendSnapshot: { [string]: any }?): (any, any)
	local labels, buttons = {}, {}
	local function node(): any
		return setmetatable({ Name = "", Text = "" }, {
			__index = function(self, key)
				return if key == "Destroy"
						or key == "Connect"
						or key == "WaitForChild"
						or key == "SetAttribute"
					then function()
						return self
					end
					else if key == "Activated" then self else nil
			end,
		})
	end
	local components = {
		label = function(_theme, props)
			local item = node()
			item.Text = props.text
			table.insert(labels, item)
			return item
		end,
		button = function(_theme, props)
			local item = node()
			item.Text, item.onClick = props.text, props.onClick
			table.insert(buttons, item)
			return item
		end,
		modalSheet = function()
			return { frame = node(), close = node(), scroll = node() }
		end,
		progressBar = function()
			return node(), function() end
		end,
	}
	local listener: any
	local state: any = {}
	local character = { definitions = { ["rw.g01.first-gather"] = true } }
	local ctx = {
		locale = "ko-kr",
		ui = { theme = { default = {} }, components = components },
		onSnapshot = function(callback)
			listener = callback
			return function() end
		end,
		send = function()
			if sendSnapshot then
				listener({ camp = state.slice, character = sendSnapshot }, state.packet)
			end
			return { ok = true }
		end,
	}
	local chunk = assert(loadstring(fs.readFile("genres/survival-coop/module/CampPanel.luau")))
	local env: any = table.clone(getfenv())
	env.game = {
		GetService = function()
			return { LocalPlayer = node() }
		end,
	}
	env.Instance, env.Enum = { new = node }, setmetatable({}, {
		__index = function()
			return {}
		end,
	})
	env.UDim2 = { new = function() end, fromScale = function() end, fromOffset = function() end }
	env.require = function(path): any
		return if path == "./CampPanelModel" then CampModel else Text
	end
	setfenv(chunk, env)
	assert(chunk().factory(ctx), "camp panel")
	local slice = {
		role = "member",
		rung = 0,
		version = 1,
		facilities = {},
		ladder = {
			rungs = { {} },
			projects = { { id = "windbreak", rung = 1, cost = { { item = "fiber", quantity = 70 } } } },
		},
		active = {},
	}
	local packet = {
		snapshots = {
			["survival-coop"] = {
				inventory = {
					{
						kind = "carried",
						reservations = {},
						items = { f = { itemId = "f", catalogId = "fiber", quantity = 3 } },
					},
				},
			},
		},
	}
	state.slice, state.packet = slice, packet
	listener({ camp = slice, character = character }, packet)
	local function notice(): string?
		local last = nil -- the final render's notice
		for _, label in labels do
			last = if label.Name == "CampNotice" then label.Text else last
		end
		return last
	end
	for _, button in buttons do
		if button.Text == CampModel.text("ko-kr", "camp_contribute") then
			table.clear(labels)
			button.onClick()
			return notice(), button
		end
	end
	error("no contribute button")
end

return {
	["1280 landscape objective holds two 14px lines and clears vitals, menu, coins and the tracker"] = function()
		for _, size in { { 1280, 642 }, { 1280, 664 }, { 1920, 1024 }, { 1076, 576 } } do
			local width, height = size[1], size[2]
			local at = width .. "x" .. height
			local hud = HUDModel.contextHudBounds(width, height)
			-- ContractsPanel tracker: 14px text, 6px top and bottom padding.
			assert(hud.objective.height >= 2 * 14 + 12, "objective one line tall at " .. at)
			for _, key in { "vitals", "menu", "coins", "biome" } do
				assert(not overlaps(hud.objective, hud[key]), "objective overlaps " .. key .. " at " .. at)
			end
			for rows = 1, 5 do
				local tracker = HUDModel.trackerBounds(width, height, rows)
				assert(not overlaps(hud.objective, tracker), "objective overlaps recipe tracker at " .. at)
				assert(tracker.y + tracker.height <= height - 128, "recipe tracker reaches the jump zone at " .. at)
			end
		end
	end,
	["a camp donation that finishes a guide shows the donation and the guide-complete line"] = function()
		local finished = { definitions = { ["rw.g01.first-gather"] = true, ["rw.g04.camp-donation"] = true } }
		local text = camp(finished)
		local guide = Text.format("ko-kr", "guide_complete", Text.text("ko-kr", "guide_g04"))
		assert(text and string.find(text, "1개 기부", 1, true), "donation line: " .. tostring(text))
		assert(string.find(text :: string, guide, 1, true), "guide line: " .. tostring(text))
		-- A plain donation shows only its own line, with no stale guide text.
		local plain = camp(nil)
		assert(
			plain and string.find(plain, "1개 기부", 1, true) and not string.find(plain, "\n", 1, true),
			tostring(plain)
		)
	end,
}
