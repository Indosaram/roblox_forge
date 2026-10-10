--!strict
-- Client: single entry point for a collect-raid pack's client experience.
-- Starts the HUD, audio, world view (incubator/creature rendering), world
-- decor, and raid replay camera from one options table.

local Hud = require("./Hud")
local Audio = require("./Audio")
local WorldView = require("./WorldView")
local WorldDecor = require("./WorldDecor")
local RaidReplay = require("./RaidReplay")

export type Options = {
	hud: Hud.Options,
	audio: Audio.Options,
	worldView: WorldView.Options,
	worldDecor: WorldDecor.Options,
	raidReplay: RaidReplay.Options,
}

local Client = {}

function Client.start(opts: Options): ()
	Hud.start(opts.hud)
	Audio.start(opts.audio)
	WorldView.start(opts.worldView)
	WorldDecor.start(opts.worldDecor)
	RaidReplay.start(opts.raidReplay)
end

return Client
