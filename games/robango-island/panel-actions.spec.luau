--!strict
-- Every durable action a client panel sends must be one the server publishes; an
-- unprefixed id ("zone-set" instead of "survival-coop:zone-set") is refused with
-- COMMAND_UNAVAILABLE by ExtensionPanels before it ever reaches the server.
local fs = require("@lune/fs")

local MODULE = "genres/survival-coop/module/"
local PANELS = { "DeathZonePanel", "ShopPanel", "TamingPanel", "ContractsPanel", "CampPanel", "MarketPanel" }

local function durableActions(): { [string]: boolean }
	local chunk = assert(loadstring(fs.readFile("games/robango-island/src/shared/GenreDurable.luau")))
	local durable: any = chunk()
	local set: { [string]: boolean } = {}
	for _, id in durable.actions do
		set[id] = true
	end
	return set
end

return {
	["panel action constants are namespaced ids the server publishes"] = function()
		local published = durableActions()
		local bad: { string } = {}
		for _, panel in PANELS do
			local source = fs.readFile(MODULE .. panel .. ".luau")
			local prefix = string.match(source, 'local PREFIX = "([^"]*)"') or ""
			for name, value in string.gmatch(source, "local ([A-Z_]+) = ([^\n]+)") do
				local literal = string.match(value, '^"([%w%-]+)"$')
				local joined = string.match(value, '^PREFIX %.%. "([%w%-]+)"$')
				local id = if joined
					then prefix .. joined
					elseif literal and string.find(literal, "%-") then literal
					else nil
				if id and name ~= "PROMPT_NAME" and not published[id] then
					table.insert(bad, panel .. "." .. name .. "=" .. id)
				end
			end
		end
		assert(#bad == 0, "unpublished panel actions: " .. table.concat(bad, ", "))
	end,
}
