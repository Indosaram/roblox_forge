--!strict
-- Single-player mode (owner: multiplayer on hold): game.yml `play_mode` is the source and
-- src/shared/PlayMode.luau its runtime mirror. The server and client scripts must read the mirror,
-- not hard-code the switches, so flipping game.yml (and the mirror) re-enables multiplayer.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local PlayMode = require("./src/shared/PlayMode")

local PACK = "games/robango-island"

local function equal(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	elseif type(a) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

return {
	["play_mode in game.yml equals the PlayMode mirror"] = function()
		local game = serde.decode("yaml", fs.readFile(PACK .. "/game.yml"))
		local declared = assert(game.play_mode, "game.yml declares play_mode")
		assert(equal(declared, PlayMode), "PlayMode.luau drifted from game.yml play_mode")
	end,
	["solo mode holds every other-player screen and lets one player finish a camp project"] = function()
		assert(PlayMode.solo == true, "the game ships single-player first")
		assert(PlayMode.campMinContributors == 1, "a solo camp project needs one contributor")
		assert(not PlayMode.flares and not PlayMode.population and not PlayMode.chat and not PlayMode.clanTag, "off")
		for _, id in { "party", "direct-trade", "clan", "players", "clan-treasury", "ensemble-lobby", "score-share" } do
			assert(PlayMode.held[id], id .. " is held off the menu")
		end
	end,
	["the client and server read the switches from PlayMode, not inline tables"] = function()
		local client = fs.readFile(PACK .. "/src/client/RobangoIslandClient.client.luau")
		local server = fs.readFile(PACK .. "/src/server/RobangoIslandServer.server.luau")
		assert(
			string.find(client, "held = require(Shared.PlayMode).held", 1, true),
			"client menu held list comes from PlayMode"
		)
		assert(
			string.find(client, "navHidden = require(Shared.PlayMode).navHidden", 1, true),
			"navigator rows come from PlayMode"
		)
		assert(not string.find(client, 'brawl = "brawl needs minimumPlayers 2"', 1, true), "no inline held table")
		assert(
			string.find(server, "visitWorld.campMinContributors = PlayMode.campMinContributors", 1, true),
			"the camp completion floor comes from PlayMode"
		)
		assert(string.find(server, "flares = PlayMode.flares", 1, true), "rescue flares follow PlayMode")
	end,
}
