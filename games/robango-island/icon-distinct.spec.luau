--!strict
-- L9 (Durango icon plan): every craft rail category and every menu tile override has published pack
-- art, so no tab or tile falls back to the shared genre glyph; one item never shows two art styles.
local fs = require("@lune/fs")
local HudShell = require("../../genres/survival-coop/module/HudShell")
local Panels = require("../../genres/survival-coop/module/ExtensionPanels")
local ItemIcons = require("../../genres/survival-coop/module/ItemIcons")
local Assets = require("./src/shared/Assets")

local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"

-- The pack dock map as the client passes it to ItemIcons.new (third argument).
local function clientDockMap(): { [string]: string }
	local source = fs.readFile(CLIENT)
	local body = string.match(source, "ItemIcons%)%.new%(content, require%(Shared%.Assets%), (%b{})%)")
	assert(body, "client passes a dock map to ItemIcons.new")
	local map: { [string]: string } = {}
	local pattern = '%[?"?([%w%-]+)"?%]?%s*=%s*"([%w%.%-]+)"'
	local at = 1
	while true do
		local first, last, key, value = string.find(body, pattern, at)
		if not first then
			break
		end
		map[key :: string] = value :: string
		at = (last :: number) + 1
	end
	return map
end

local icons = ItemIcons.new({ items = {}, recipes = {} }, Assets :: any, clientDockMap())

return {
	["every craft category tab has published art"] = function()
		for _, id in HudShell.PANEL_CATEGORY_ORDER do
			local icon = icons.ui("cat." .. id)
			assert(icon.image ~= nil, "ui.icon.cat." .. id .. " is not published")
		end
	end,
	["every pack menu tile override resolves to distinct published art"] = function()
		local seen: { [string]: string } = {}
		for dockId, iconId in icons.dock :: { [string]: string } do
			assert(Panels.iconId(dockId, icons) == iconId, "override applies for " .. dockId)
			local default = Panels.iconId(dockId)
			assert(default ~= iconId, dockId .. " override must differ from the shared default")
			local icon = icons.ui(iconId)
			assert(icon.image ~= nil, "ui.icon." .. iconId .. " is not published")
			assert(seen[icon.image :: string] == nil, iconId .. " repeats " .. tostring(seen[icon.image :: string]))
			seen[icon.image :: string] = iconId
		end
	end,
}
