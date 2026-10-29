--!strict
-- p134 v51/v52 (SM-N981N, staging): the L9 painted icons showed nowhere on the phone. Menu, bag
-- and craft kept the generic glyphs, and the gather fan pebbles and down-card badges were empty.
-- The device logcat named the cause: `AssetDelivery403InvalidPermission ... User is not authorized
-- to access Asset` for the ui/item art. The ids are right and Approved (the live server's
-- ContentProvider loads all 485 of them), but the account creates Restricted images (Asset
-- Privacy). A published experience draws them only after the owner grants the universe Use, which
-- is what `forge assets grant` does. Studio hid it because the creator's own permission applies
-- there.
-- This spec pins the client half on the real wiring:
--   1. every icon key the bag, craft list, craft category rail, gather fan, down panel, vitals and
--      menu dock ask for resolves through Assets.luau and the client's dock map to an rbxassetid;
--   2. a fan pebble and a down-card badge whose art never loads keep a visible stand-in (the
--      item or option initial). Before this change both were blank.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox: any = require("@lune/roblox")
local ImageLoad = require("../../core/ui-kit/ImageLoad.fixture")
local ItemIcons = require("../../genres/survival-coop/module/ItemIcons")
local HudShell = require("../../genres/survival-coop/module/HudShell")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local DownPanel = require("../../genres/survival-coop/module/DownPanel")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local Assets = require("./src/shared/Assets")
local content: any = require("./src/shared/SurvivalContent")
local _packText = require("./PackText.fixture")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"
local ASSET = "^rbxassetid://[1-9]%d*$"

-- The pack dock map exactly as the client passes it to ItemIcons.new (third argument).
local function clientDockMap(): { [string]: string }
	local source = fs.readFile(CLIENT)
	local body = string.match(source, "ItemIcons%)%.new%(content, require%(Shared%.Assets%), (%b{})%)")
	assert(body, "client builds its icon catalog with ItemIcons.new(content, Assets, dock)")
	local map: { [string]: string } = {}
	for key, value in string.gmatch(body, '%[?"?([%w%-]+)"?%]?%s*=%s*"([%w%.%-]+)"') do
		map[key :: string] = value :: string
	end
	return map
end

local icons = ItemIcons.new(content, Assets :: any, clientDockMap())

local function signal()
	return {
		Connect = function()
			return { Disconnect = function() end }
		end,
	}
end

local function moduleEnvironment(services: { [string]: any }): any
	local environment: any = {
		game = {
			GetService = function(_, name)
				return services[name]
			end,
		},
		task = {
			spawn = function(fn, ...)
				fn(...)
			end,
		},
	}
	for key, value in roblox do
		environment[key] = value
	end
	environment.Instance = ImageLoad.instance(function(made)
		if made:IsA("GuiObject") then
			made.AbsoluteSize = roblox.Vector2.new(48, 48)
		end
	end)
	-- Registered once per process; another spec in the run may have done it already.
	pcall(roblox.implementProperty, "TextButton", "Activated", function()
		return signal()
	end)
	return environment
end

local function loadShell(environment: any): any
	return luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), { environment = environment })()
end

return {
	["every icon the bag, craft, fan, down panel, vitals and menu ask for is an Assets rbxassetid"] = function()
		local missing: { string } = {}
		local function need(what: string, image: string?)
			if type(image) ~= "string" or not string.match(image, ASSET) then
				table.insert(missing, what)
			end
		end
		-- Bag slots and craft material rows: every catalog item (SurvivalHUD itemIcon).
		for _, item in content.items do
			need("item " .. item.id, icons.item(item.id).image)
		end
		-- Craft list rows: the recipe art, else the first output's item art (SurvivalHUD:1511).
		for _, recipe in content.recipes do
			local icon = icons.recipe(recipe.id)
			need("recipe " .. recipe.id, icon.image or icons.item(recipe.outputs[1].item).image)
		end
		-- Craft category rail: ui.icon.cat.<id> for every rail id.
		for _, id in HudShell.PANEL_CATEGORY_ORDER do
			need("cat " .. id, icons.ui("cat." .. id).image)
		end
		-- Gather fan: every output any node can offer (the client's icon callback is item().image).
		for _, node in content.nodes do
			for _, output in (Gathering.offered(content, node.id, "")) do
				need("fan " .. node.id .. "/" .. output.item, icons.item(output.item).image)
			end
		end
		for _, layout in content.layouts or {} do
			for _, resource in layout.resourceNodes or {} do
				for _, output in (Gathering.offered(content, "", resource.id)) do
					need("fan " .. resource.id .. "/" .. output.item, icons.item(output.item).image)
				end
			end
		end
		-- Down cards: each option's badge item.
		for option in DownPanel.ICON_ASSETS do
			need("down " .. option, DownPanel.icon(icons, option))
		end
		-- Vitals (SurvivalHUD: hunger reads the energy icon).
		for _, stat in { "health", "energy", "fatigue" } do
			need("vital " .. stat, icons.ui(stat).image)
		end
		-- Menu dock tiles: the pack override or the genre default for every dock id.
		for dockId in Panels.DOCK_ICONS do
			need("dock " .. dockId, icons.ui(Panels.iconId(dockId, icons)).image)
		end
		for dockId in icons.dock :: { [string]: string } do
			need("dock " .. dockId, icons.ui(Panels.iconId(dockId, icons)).image)
		end
		assert(#missing == 0, "no published art for: " .. table.concat(missing, ", "))
	end,
	["a gather fan pebble keeps the item initial until its art loads"] = function()
		local gui = roblox.Instance.new("ScreenGui")
		local node = roblox.Instance.new("Part")
		node.Parent = roblox.Instance.new("Folder")
		local services: { [string]: any } = {
			RunService = { RenderStepped = signal() },
			GuiService = {},
			UserInputService = { InputBegan = signal() },
			Players = { LocalPlayer = {} },
			Workspace = {},
		}
		local shell = loadShell(moduleEnvironment(services))
		local picker = shell.startPicker({
			gui = gui,
			touch = function()
				return true
			end,
			hidden = function()
				return false
			end,
			offered = function()
				return { { item = "fiber", quantity = 2 }, { item = "leaves", quantity = 2 } }, 1
			end,
			nodeName = function()
				return "fern"
			end,
			itemName = function(item)
				return if item == "fiber" then "고사리 섬유" else "나뭇잎"
			end,
			-- The client's callback (RobangoIslandClient: icon = itemIcons.item(item).image).
			icon = function(item)
				return icons.item(item).image
			end,
			gather = function()
				return { ok = true }
			end,
			text = function(key)
				return key
			end,
			reach = 10,
		})
		assert(picker.open(node), "fan opens")
		local root = gui:FindFirstChildWhichIsA("Frame", true)
		local token = assert(gui:FindFirstChild("Output1", true), "first output pebble")
		local image, glyph = token:FindFirstChild("Icon"), token:FindFirstChild("Glyph")
		assert(root and string.match(image.Image, ASSET), "the pebble asks for the fiber art")
		-- On the phone the art never loaded (403): the pebble must not be blank.
		assert(glyph.Visible and glyph.Text == "고", "the initial shows while the art has not loaded")
		ImageLoad.load(image, true)
		assert(not glyph.Visible, "the initial hides once the art has loaded")
		picker.destroy()
	end,
	["a down card badge keeps the option initial until its art loads"] = function()
		local I = roblox.Instance
		local playerGui = I.new("PlayerGui")
		local services: { [string]: any } = {
			Players = {
				LocalPlayer = {
					PlayerGui = playerGui,
					WaitForChild = function()
						return playerGui
					end,
				},
				GetPlayerByUserId = function()
					return nil
				end,
			},
			Lighting = I.new("Lighting"),
			RunService = { Heartbeat = signal() },
			TextChatService = {
				FindFirstChild = function()
					return nil
				end,
			},
		}
		local environment = moduleEnvironment(services)
		environment.task = { spawn = function() end }
		local shell = loadShell(environment)
		environment.require = function(path: string)
			return if path == "./HudShell"
				then shell
				else require("../../genres/survival-coop/module/PackLocale") :: any
		end
		local panel = luau.load(fs.readFile("genres/survival-coop/module/DownPanel.luau"), {
			chunkName = "DownPanel",
			environment = environment,
		})()
		local render: any = nil
		assert(
			panel.factory({
				locale = "ko-kr",
				icons = icons,
				send = function()
					return { ok = true }
				end,
				onSnapshot = function(fn)
					render = fn
					return function() end
				end,
			}),
			"factory subscribed"
		)
		render({ rescue = { down = true, options = { "rift", "camp", "rescue" } } })
		local row = playerGui:FindFirstChild("ForgeDownPanel"):FindFirstChild("DownCards")
		local cards = 0
		for _, button in row:GetChildren() do
			if button:IsA("TextButton") and button.Visible then
				cards += 1
				local badge = button:FindFirstChild("Icon")
				local inner, glyph = badge:FindFirstChild("Image"), badge:FindFirstChild("Glyph")
				assert(string.match(inner.Image, ASSET), "the badge asks for its item art")
				assert(glyph and glyph.Visible and glyph.Text ~= "", "the initial shows while the art has not loaded")
				ImageLoad.load(inner, true)
				assert(not glyph.Visible, "the initial hides once the art has loaded")
			end
		end
		assert(cards == 3, "three down cards, got " .. cards)
	end,
}
