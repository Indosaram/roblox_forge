--!strict
-- Every modal sheet the robango client mounts (its own client script and the survival-coop
-- panels) wires its header X: each `local <sheet> = ...modalSheet(` has a matching
-- `<sheet>.close.Activated:Connect` in the same file. The Building sheet once had none, so
-- its X (and Escape/Menu) left it stuck open over the HUD.
local fs = require("@lune/fs")

local MODULES = "genres/survival-coop/module/"
local CLIENT = "games/robango-island/src/client/RobangoIslandClient.client.luau"

local function audit(path: string)
	local source = fs.readFile(path)
	local made: { [string]: number } = {}
	for name in string.gmatch(source, "local%s+([%w_]+)%s*=%s*[%w_%.]*modalSheet%(") do
		made[name] = (made[name] or 0) + 1
	end
	for name, count in made do
		local _, wired = string.gsub(source, name .. "%.close%.Activated:Connect", "")
		-- A sheet whose X is taken into a shared `close` local (ScoreEditorPanel keeps one close
		-- path for its themed and fallback sheets) is wired through that local.
		if
			wired < count
			and string.find(source, name .. "%.close[%s,\n]")
			and string.find(source, "[^%w_%.]close%.Activated:Connect")
		then
			wired = count
		end
		assert(wired >= count, string.format("%s: %d %s sheet(s) but %d close wiring(s)", path, count, name, wired))
	end
	return made
end

return {
	["every robango client and survival-coop modal sheet closes from its header X"] = function()
		local sheets = 0
		for _, name in fs.readDir(MODULES) do
			if string.sub(name, -5) == ".luau" and not string.find(name, "%.spec%.luau$") then
				for _, count in audit(MODULES .. name) do
					sheets += count
				end
			end
		end
		local client = audit(CLIENT)
		assert(client.sheet == 2 and client.inputSheet == 1, "building, audio and clan input sheets audited")
		assert(sheets >= 15, "survival-coop sheets audited: " .. sheets)
	end,
	["the building sheet's X hides it"] = function()
		local source = fs.readFile(CLIENT)
		local start = assert(string.find(source, 'name = "Building"', 1, true), "building sheet")
		local stop = assert(string.find(source, 'id = "building"', start, true), "building dock")
		local body = string.sub(source, start, stop)
		local callback =
			assert(string.match(body, "sheet%.close%.Activated:Connect%((function%(%)%s+.-end)%)"), "X handler")
		local sheet = { frame = { Visible = true } }
		local handler = assert(loadstring("return function(sheet) return " .. callback .. " end"))()(sheet)
		handler()
		assert(not sheet.frame.Visible, "building X hides the open sheet")
	end,
}
