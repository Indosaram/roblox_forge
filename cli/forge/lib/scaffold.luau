--!strict
-- scaffold: pure text templates for `forge new`. Kept apart from the command so the
-- exact bytes a new pack starts from are testable under Lune (no filesystem).
--
-- `gameYml` and `projectJson` are genre-agnostic; `collectRaidFiles` adds the
-- playable collect-raid starter (world data, server loop, ui-kit HUD, procgen
-- asset specs) so a fresh pack runs in Studio with no hand-written code.

local CollectScaffold = require("../../../genres/collect-raid/generation/scaffold")
local Identity = require("./packidentity")

local M = {}

local ART_STYLE = '"stylized low-poly, chunky silhouettes, bright saturated palette, soft ambient light"'
local POLY_BUDGET = "{ creature: 2000, prop: 800, world_parts_max: 5000 }"

--- True for a lowercase-kebab slug (a-z, 0-9, single hyphens, no leading/trailing).
M.isValidSlug = Identity.isValidSlug
M.titleCase = Identity.titleCase
M.pascalCase = Identity.pascalCase

--- Replaces `__NAME__` placeholders. `string.gsub` gets a function replacement so
--- a value containing `%` is inserted literally.
M.fill = Identity.fill

--- game.yml for a fresh pack. art_style and poly_budget carry real defaults (never
--- `TBD`), so the new pack passes the check [game] stage immediately.
function M.gameYml(slug: string, genres: { string }): string
	return table.concat({
		"name: " .. M.titleCase(slug),
		"slug: " .. slug,
		"genres: [" .. table.concat(genres, ", ") .. "]",
		"currencies: [Coins]",
		"monetization: {gamepasses: [], products: [], subscriptions: []}",
		"art_style: " .. ART_STYLE,
		"poly_budget: " .. POLY_BUDGET,
		"locales: [en-us]",
		-- The one language a generated pack renders; every HUD string resolves
		-- through the pack's locale table at this code.
		"locale: {default: en}",
		"qa_scenarios: [core-loop]",
		"liveops_cadence: weekly",
		"",
	}, "\n")
end

--- default.project.json mirroring the kaiju-egg-raiders pack: Forge.core (domain,
--- infra, anticheat, ui-kit), every requested genre module, the pack's shared
--- folder, Remotes, the server script, and the client script.
function M.projectJson(slug: string, pascal: string, genres: { string }): string
	local lines: { string } = {
		"{",
		'\t"name": "' .. slug .. '",',
		'\t"globIgnorePaths": ["**/*.spec.luau", "**/*.md", "**/.gitkeep", "**/*.yml"],',
		'\t"tree": {',
		'\t\t"$className": "DataModel",',
		'\t\t"ReplicatedStorage": {',
		'\t\t\t"Remotes": { "$className": "Folder" },',
		'\t\t\t"Forge": {',
		'\t\t\t\t"$className": "Folder",',
		'\t\t\t\t"core": {',
		'\t\t\t\t\t"$className": "Folder",',
		'\t\t\t\t\t"domain": { "$path": "../../core/domain" },',
		'\t\t\t\t\t"infra": { "$path": "../../core/infra" },',
		'\t\t\t\t\t"anticheat": { "$path": "../../core/anticheat" },',
		'\t\t\t\t\t"ui-kit": { "$path": "../../core/ui-kit" }',
		"\t\t\t\t},",
		'\t\t\t\t"genres": {',
		'\t\t\t\t\t"$className": "Folder",',
	}
	for index, genre in genres do
		table.insert(lines, '\t\t\t\t\t"' .. genre .. '": {')
		table.insert(lines, '\t\t\t\t\t\t"$className": "Folder",')
		table.insert(lines, '\t\t\t\t\t\t"module": { "$path": "../../genres/' .. genre .. '/module" }')
		local comma = if index < #genres then "," else ""
		table.insert(lines, "\t\t\t\t\t}" .. comma)
	end
	table.insert(lines, "\t\t\t\t},")
	table.insert(lines, '\t\t\t\t"games": {')
	table.insert(lines, '\t\t\t\t\t"$className": "Folder",')
	table.insert(lines, '\t\t\t\t\t"' .. slug .. '": {')
	table.insert(lines, '\t\t\t\t\t\t"$className": "Folder",')
	table.insert(lines, '\t\t\t\t\t\t"src": {')
	table.insert(lines, '\t\t\t\t\t\t\t"$className": "Folder",')
	table.insert(lines, '\t\t\t\t\t\t\t"shared": { "$path": "src/shared" }')
	table.insert(lines, "\t\t\t\t\t\t}")
	table.insert(lines, "\t\t\t\t\t}")
	table.insert(lines, "\t\t\t\t}")
	table.insert(lines, "\t\t\t}")
	table.insert(lines, "\t\t},")
	table.insert(lines, '\t\t"ServerScriptService": {')
	table.insert(lines, '\t\t\t"' .. pascal .. 'Server": { "$path": "src/server/' .. pascal .. 'Server.server.luau" }')
	table.insert(lines, "\t\t},")
	table.insert(lines, '\t\t"StarterPlayer": {')
	table.insert(lines, '\t\t\t"StarterPlayerScripts": {')
	table.insert(
		lines,
		'\t\t\t\t"' .. pascal .. 'Client": { "$path": "src/client/' .. pascal .. 'Client.client.luau" }'
	)
	table.insert(lines, "\t\t\t}")
	table.insert(lines, "\t\t}")
	table.insert(lines, "\t}")
	table.insert(lines, "}")
	table.insert(lines, "")
	return table.concat(lines, "\n")
end

--- Generic shared Config stub for packs whose genre ships no starter.
function M.configStub(slug: string): string
	return table.concat({
		"--!strict",
		"-- Config: pure data configuration for " .. M.titleCase(slug) .. ".",
		"",
		'local EconConfig = require("./EconConfig")',
		"",
		"local Config = {}",
		"",
		"Config.currency = EconConfig.currency",
		"Config.startingCoins = EconConfig.startingCoins",
		"Config.maxIncubators = EconConfig.maxIncubators",
		"",
		"return Config",
		"",
	}, "\n")
end

--- Generic server stub for packs whose genre ships no starter.
function M.serverStub(slug: string, pascal: string): string
	return table.concat({
		"--!strict",
		"-- " .. pascal .. "Server: bootstrap server stub for the " .. slug .. " pack.",
		"",
		'local ReplicatedStorage = game:GetService("ReplicatedStorage")',
		"local Forge = ReplicatedStorage.Forge",
		'local Config = require(Forge.games["' .. slug .. '"].src.shared.Config)',
		"",
		'print("' .. slug .. ' server starting with " .. Config.startingCoins .. " " .. Config.currency)',
		"",
	}, "\n")
end

--- Generic client stub for packs whose genre ships no starter.
function M.clientStub(slug: string, pascal: string): string
	return table.concat({
		"--!strict",
		"-- " .. pascal .. "Client: bootstrap client stub for the " .. slug .. " pack.",
		"",
		'print("' .. slug .. ' client ready")',
		"",
	}, "\n")
end

M.collectRaidFiles = CollectScaffold.collectRaidFiles

return M
