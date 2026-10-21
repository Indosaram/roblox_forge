--!strict
local Director = require("./AudioDirector")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local Catalog = luau.load(fs.readFile("games/robango-island/src/shared/RobangoAudioCatalog.luau"))()
local function fixture(module: any?)
	local plays, stops, volumes = {}, {}, {}
	local director = (module or Director).new(Catalog, {
		play = function(name, slot)
			table.insert(plays, { name = name, group = slot.group })
		end,
		stop = function(name)
			table.insert(stops, name)
		end,
		volume = function(group, gain)
			volumes[group] = gain
		end,
	})
	return director, plays, stops, volumes
end
local function rejectsUncommitted(module: any)
	local d, plays = fixture(module)
	local req = { action = "survival-coop:gather", requestId = "1", sessionEpoch = 1 }
	local results: { any } = {
		{ ok = false, stateVersion = 1 },
		{ ok = true },
		{ ok = true, stateVersion = 1, data = { status = "pending" } },
		{ ok = true, stateVersion = 1, data = { status = "recovering" } },
	}
	for _, res in results do
		d.result(req, res, "gather-wood")
	end
	assert(#plays == 0, "uncommitted results are silent")
end
local function suppressesDuplicates(module: any)
	local d, plays = fixture(module)
	local req = { action = "survival-coop:gather", requestId = "1", sessionEpoch = 1 }
	local res = { ok = true, stateVersion = 1, data = { status = "confirmed" } }
	d.result(req, res, "gather-wood")
	d.result(req, res, "gather-wood")
	assert(#plays == 1, "one cue per retained receipt")
	req.sessionEpoch = 2
	d.result(req, res, "gather-wood")
	assert(#plays == 2, "new epoch is independent")
end
return {
	["all configured events and regions select their own slot and mixer group"] = function()
		local d, plays, stops = fixture()
		for event, slot in Catalog.events do
			assert(d.event(event), "audio director invariant")
			assert(
				plays[#plays].name == slot and plays[#plays].group == Catalog.slots[slot].group,
				"audio director invariant"
			)
		end
		local count = #plays
		assert(not d.event("unknown") and not d.region("unknown") and #plays == count, "audio director invariant")
		for region, slot in Catalog.regions do
			assert(d.region(region), "audio director invariant")
			assert(plays[#plays].name == slot, "audio director invariant")
			local before = #plays
			d.region(region)
			assert(#plays == before, "same region must not restart music")
		end
		assert(#stops == 8, "each transition stops previous region")
	end,
	["pending failed replayed and malformed commands do not produce victory cues"] = function()
		rejectsUncommitted(Director)
		suppressesDuplicates(Director)
		local d, plays = fixture()
		for _, req in { {}, { action = "x" }, { requestId = "x" } } do
			assert(not d.result(req, { ok = true, stateVersion = 1 }, "reward"), "malformed request rejected")
		end
		assert(not d.result(nil, nil, "reward") and #plays == 0, "nil packet rejected")
	end,
	["mute restores group preferences and silences one shots while loops retain state"] = function()
		local d, plays, stops, volumes = fixture()
		assert(d.setVolume("Music", 0.6), "valid gain accepted")
		d.event("campfire")
		d.event("campfire")
		assert(#plays == 1, "audio director invariant")
		d.setMuted(true)
		for _, gain in volumes do
			assert(gain == 0, "muted gain")
		end
		d.event("reward")
		assert(#plays == 1, "audio director invariant")
		assert(d.setVolume("Music", 0.4) and volumes.Music == 0, "muted gain retained")
		d.setMuted(false)
		assert(volumes.Music == 0.4 and volumes.SFX == 0.45, "audio director invariant")
		for _, gain in { -1, 2, math.huge, 0 / 0 } do
			assert(not d.setVolume("Music", gain), "invalid gain refused")
		end
		assert(not d.setVolume("invented", 0.5), "unknown group refused")
		d.event("campfire", false)
		d.event("campfire", false)
		assert(#stops == 1, "audio director invariant")
		d.region("home")
		d.event("campfire")
		d.destroy()
		local count = #stops
		d.destroy()
		assert(
			not d.event("reward") and not d.region("forest") and not d.setVolume("Music", 1),
			"disposed director silent"
		)
		assert(#stops == count and count == 3, "audio director invariant")
	end,
	["negative assertions kill pending and replay policy mutations"] = function()
		local source = fs.readFile("genres/survival-coop/module/AudioDirector.luau")
		local pending, count = string.gsub(source, 'data.status ~= "confirmed"', "false", 1)
		assert(count == 1, "audio director invariant")
		assert(not pcall(rejectsUncommitted, luau.load(pending)()), "pending guard mutation must fail")
		local replay, replayCount = string.gsub(source, "if seen%[identity%] then", "if false then", 1)
		assert(replayCount == 1, "audio director invariant")
		assert(not pcall(suppressesDuplicates, luau.load(replay)()), "replay guard mutation must fail")
	end,
}
