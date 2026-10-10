--!strict
local fs = require("@lune/fs")
local luau = require("@lune/luau")

-- Coroutines suspend exactly at the real playlist wait boundary. No sleeps.
local function fixture(): any
	local debris, threads = {}, {}
	local services: any = {
		SoundService = {
			FindFirstChild = function()
				return nil
			end,
		},
		ContentProvider = { PreloadAsync = function() end },
		Debris = {
			AddItem = function(_, sound, lifetime)
				debris[sound] = lifetime
			end,
		},
		TweenService = {
			Create = function(_, sound, _, properties)
				return {
					Play = function()
						for key, value in properties do
							sound[key] = value
						end
					end,
					Completed = { Wait = function() end },
				}
			end,
		},
	}
	local module = luau.load(fs.readFile("core/infra/audio/SoundBank.luau"), {
		environment = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			Instance = {
				new = function(kind)
					return {
						ClassName = kind,
						TimeLength = 10,
						Play = function(self)
							self.played = true
						end,
						Destroy = function(self)
							self.destroyed = true
							self.Parent = nil
						end,
					}
				end,
			},
			TweenInfo = {
				new = function(duration)
					return duration
				end,
			},
			task = {
				spawn = function(callback)
					local thread = coroutine.create(callback)
					table.insert(threads, thread)
					assert(coroutine.resume(thread))
				end,
				wait = function()
					return coroutine.yield()
				end,
				delay = function()
					error("unexpected delayed cleanup")
				end,
			},
		},
	})()
	return { bank = module.new(), debris = debris, threads = threads }
end

return {
	["one-shots assign mixer groups independently of positional parents and overrides"] = function()
		local f = fixture()
		local bank = f.bank
		bank:define("click", { soundId = "rbxassetid://1", group = "SFX", volume = 0.7, playbackSpeed = 1.2 })
		local positional = {}
		local sound = bank:play("click", { parent = positional, group = "UI", volume = 0.2, playbackSpeed = 2 })
		assert(sound.SoundGroup == bank.groups.UI, "positional parent must not bypass mixer assignment")
		assert(
			sound.Parent == positional and sound.Volume == 0.2 and sound.PlaybackSpeed == 2,
			"sound.Parent == positional and sound.Volume == 0.2 and sound.PlaybackSpeed == 2"
		)
		assert(sound.played and f.debris[sound] == 12, "sound.played and f.debris[sound] == 12")
		local default = bank:play("click")
		assert(
			default.SoundGroup == bank.groups.SFX and default.Parent == bank.groups.SFX,
			"default.SoundGroup == bank.groups.SFX and default.Parent == bank.groups.SFX"
		)
		assert(
			default.Volume == 0.7 and default.PlaybackSpeed == 1.2,
			"default.Volume == 0.7 and default.PlaybackSpeed == 1.2"
		)
		bank:setGroupVolume("UI", 0.1)
		assert(sound.SoundGroup.Volume == 0.1, "sound.SoundGroup.Volume == 0.1")
		local loop = bank:play("click", { looped = true })
		assert(loop.Looped and f.debris[loop] == nil, "loop.Looped and f.debris[loop] == nil")
		assert(bank:play("missing") == nil, 'bank:play("missing") == nil')
	end,
	["playlist assigns default and cue mixer groups and cancels at a deterministic boundary"] = function()
		local f = fixture()
		local bank = f.bank
		bank:define("music", { soundId = "rbxassetid://2", volume = 0.8 })
		bank:define("other", { soundId = "rbxassetid://3", group = "UI" })
		bank:playPlaylist({ "music", "other" }, { crossfade = 0, volume = 0.5 })
		local first = bank.musicSound
		assert(first.SoundGroup == bank.groups.Music, "playlist must assign Sound.SoundGroup")
		assert(
			first.Parent == bank.groups.Music and first.Volume == 0.4 and first.played,
			"first.Parent == bank.groups.Music and first.Volume == 0.4 and first.played"
		)
		-- Advance simulated elapsed time at the exact suspended wait boundary.
		assert(coroutine.resume(f.threads[1], 10))
		local second = bank.musicSound
		assert(
			second ~= first and second.SoundGroup == bank.groups.UI and second.Parent == bank.groups.UI,
			"second ~= first and second.SoundGroup == bank.groups.UI and second.Parent == bank.groups.UI"
		)
		assert(first.destroyed and second.Volume == 0.5, "first.destroyed and second.Volume == 0.5")
		bank:setGroupVolume("UI", 0.2)
		assert(second.SoundGroup.Volume == 0.2, "second.SoundGroup.Volume == 0.2")
		bank:stopPlaylist(0)
		assert(second.destroyed and bank.musicSound == nil, "second.destroyed and bank.musicSound == nil")
		assert(coroutine.resume(f.threads[1], 10))
		assert(coroutine.status(f.threads[1]) == "dead", 'coroutine.status(f.threads[1]) == "dead"')
		bank:destroy()
	end,
}
