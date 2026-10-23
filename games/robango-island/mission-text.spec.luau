--!strict
-- Every authored mission NPC line resolves in EN and KO from locale/strings.csv, the one source the
-- client reads (shipped as the Forge.games["robango-island"].Strings LocalizationTable).
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local MissionText = require("./PackText.fixture").authored
local Content = require("./src/shared/SurvivalContent")

local function columns(line: string): { string }
	local out, field, quoted, index = {}, {}, false, 1
	while index <= #line do
		local char = string.sub(line, index, index)
		if quoted then
			if char == '"' and string.sub(line, index + 1, index + 1) == '"' then
				table.insert(field, '"')
				index += 1
			elseif char == '"' then
				quoted = false
			else
				table.insert(field, char)
			end
		elseif char == '"' then
			quoted = true
		elseif char == "," then
			table.insert(out, table.concat(field))
			field = {}
		else
			table.insert(field, char)
		end
		index += 1
	end
	table.insert(out, table.concat(field))
	return out
end

return {
	["every mission dialogue key resolves to its strings.csv text in both locales"] = function()
		local rows: { [string]: { string } } = {}
		for _, line in string.split(fs.readFile("games/robango-island/locale/strings.csv"), "\n") do
			local row = columns((string.gsub(line, "\r$", "")))
			rows[row[1]] = row
		end
		local count = 0
		for _, mission in (Content :: any).missions do
			for _, key in mission.dialogueKeys do
				local row = assert(rows[key], "csv row " .. key)
				assert(MissionText("en-us", key) == row[4], "en line " .. key)
				assert(MissionText("ko-kr", key) == row[5], "ko line " .. key)
				count += 1
			end
		end
		assert(count >= 60, "all mission offer/complete lines covered")
	end,
	["the client's LocalizationTable is built from strings.csv"] = function()
		local project = serde.decode("json", fs.readFile("games/robango-island/default.project.json"))
		local pack = project.tree.ReplicatedStorage.Forge.games["robango-island"]
		assert(pack.Strings["$path"] == "locale/strings.csv", "Strings LocalizationTable ships strings.csv")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(
			string.find(client, 'PackText.fromEntries(Forge.games["robango-island"].Strings:GetEntries())', 1, true),
			"client reads pack copy from the shipped table"
		)
	end,
}
