--!strict
-- SoundBank: a tiny generic client audio layer for Forge games. Cues are
-- registered by name, preloaded, and played as one-shots or loops through
-- SoundGroups (Music/SFX/UI). A music playlist loops with a crossfade.
-- Engine-bound adapter; contains no gameplay logic.

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local DEFAULT_GROUP_VOLUMES: { [string]: number } = {
	Music = 0.35,
	SFX = 0.6,
	UI = 0.5,
}

export type Cue = {
	soundId: string,
	volume: number?,
	playbackSpeed: number?,
	looped: boolean?,
	group: string?,
}

export type PlayOptions = {
	volume: number?,
	playbackSpeed: number?,
	looped: boolean?,
	parent: Instance?,
	group: string?,
}

export type PlaylistOptions = {
	crossfade: number?,
	volume: number?,
}

export type SoundBank = {
	cues: { [string]: Cue },
	groups: { [string]: SoundGroup },
	musicToken: number,
	musicSound: Sound?,
	musicPrevious: Sound?,
	define: (self: SoundBank, name: string, cue: Cue) -> (),
	preload: (self: SoundBank, names: { string }?) -> (),
	play: (self: SoundBank, name: string, opts: PlayOptions?) -> Sound?,
	playPlaylist: (self: SoundBank, names: { string }, opts: PlaylistOptions?) -> (),
	stopPlaylist: (self: SoundBank, fade: number?) -> (),
	setGroupVolume: (self: SoundBank, group: string, volume: number) -> (),
	destroy: (self: SoundBank) -> (),
}

local SoundBank = {}
SoundBank.__index = SoundBank

local function resolveGroup(self: SoundBank, name: string): SoundGroup
	local cached: SoundGroup? = self.groups[name]
	if cached ~= nil then
		return cached
	end
	local group: SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing ~= nil and existing:IsA("SoundGroup") then
		group = existing
	else
		local created = Instance.new("SoundGroup") :: SoundGroup
		created.Name = name
		created.Parent = SoundService
		group = created
	end
	group.Volume = DEFAULT_GROUP_VOLUMES[name] or 1
	self.groups[name] = group
	return group
end

-- Waits (bounded) for the engine to report a length; 60s is the fallback so a
-- failed load can never wedge the playlist.
local function awaitLength(sound: Sound): number
	if sound.TimeLength > 0 then
		return sound.TimeLength
	end
	local deadline = os.clock() + 5
	while sound.Parent ~= nil and sound.TimeLength <= 0 and os.clock() < deadline do
		task.wait(0.1)
	end
	if sound.TimeLength > 0 then
		return sound.TimeLength
	end
	return 60
end

function SoundBank.new(groupVolumes: { [string]: number }?): SoundBank
	local self: any = setmetatable({
		cues = {},
		groups = {},
		musicToken = 0,
		musicSound = nil,
		musicPrevious = nil,
	}, SoundBank)
	for name, volume in groupVolumes or DEFAULT_GROUP_VOLUMES do
		resolveGroup(self, name).Volume = volume
	end
	return self :: SoundBank
end

function SoundBank.define(self: SoundBank, name: string, cue: Cue): ()
	self.cues[name] = cue
end

function SoundBank.preload(self: SoundBank, names: { string }?): ()
	local ids: { string } = {}
	local function add(name: string)
		local cue: Cue? = self.cues[name]
		if cue ~= nil and cue.soundId ~= "" then
			table.insert(ids, cue.soundId)
		end
	end
	if names == nil then
		for name in self.cues do
			add(name)
		end
	else
		for _, name in names do
			add(name)
		end
	end
	if #ids == 0 then
		return
	end
	pcall(function()
		ContentProvider:PreloadAsync(ids)
	end)
end

--- Plays a registered cue. Without opts the cue's own volume/speed/loop/group
--- are used; opts override any of them. One-shots are cleaned up via Debris.
function SoundBank.play(self: SoundBank, name: string, opts: PlayOptions?): Sound?
	local cue: Cue? = self.cues[name]
	if cue == nil or cue.soundId == "" then
		return nil
	end
	local options: PlayOptions = opts or {}
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = cue.soundId
	sound.Volume = options.volume or cue.volume or 1
	sound.PlaybackSpeed = options.playbackSpeed or cue.playbackSpeed or 1
	sound.Looped = if options.looped ~= nil then options.looped else cue.looped == true
	sound.SoundGroup = resolveGroup(self, options.group or cue.group or "SFX")
	sound.Parent = options.parent or sound.SoundGroup
	sound:Play()
	if not sound.Looped then
		Debris:AddItem(sound, 12)
	end
	return sound
end

--- Loops the given cue names forever, crossfading each track into the next.
--- Calling again (or stopPlaylist) cancels the previous playlist.
function SoundBank.playPlaylist(self: SoundBank, names: { string }, opts: PlaylistOptions?): ()
	self:stopPlaylist(0)
	if #names == 0 then
		return
	end
	local options: PlaylistOptions = opts or {}
	local crossfade = options.crossfade or 2
	local volume = options.volume or 1
	local token = self.musicToken
	task.spawn(function()
		local index = 1
		while self.musicToken == token do
			local name = names[index]
			local cue: Cue? = self.cues[name]
			if cue == nil or cue.soundId == "" then
				break
			end
			local sound = Instance.new("Sound")
			sound.Name = name
			sound.SoundId = cue.soundId
			sound.Looped = false
			sound.Volume = 0
			sound.PlaybackSpeed = cue.playbackSpeed or 1
			sound.SoundGroup = resolveGroup(self, cue.group or "Music")
			sound.Parent = sound.SoundGroup
			sound:Play()

			local target = (cue.volume or 1) * volume
			TweenService:Create(sound, TweenInfo.new(crossfade), { Volume = target }):Play()

			local previous = self.musicPrevious
			self.musicPrevious = sound
			self.musicSound = sound
			if previous ~= nil then
				task.spawn(function()
					local tween = TweenService:Create(previous, TweenInfo.new(crossfade), { Volume = 0 })
					tween:Play()
					tween.Completed:Wait()
					previous:Destroy()
				end)
			end

			local remaining = math.max(0.1, awaitLength(sound) - crossfade)
			local elapsed = 0
			while elapsed < remaining and self.musicToken == token do
				elapsed += task.wait(0.25)
			end
			index = index % #names + 1
		end
	end)
end

function SoundBank.stopPlaylist(self: SoundBank, fade: number?): ()
	self.musicToken += 1
	local sound = self.musicSound
	local previous = self.musicPrevious
	self.musicSound = nil
	self.musicPrevious = nil
	local fadeTime = fade or 0
	for _, item in { sound, previous } do
		if item ~= nil then
			if fadeTime <= 0 then
				item:Destroy()
			else
				local tween = TweenService:Create(item, TweenInfo.new(fadeTime), { Volume = 0 })
				tween:Play()
				task.delay(fadeTime, function()
					item:Destroy()
				end)
			end
		end
	end
end

function SoundBank.setGroupVolume(self: SoundBank, group: string, volume: number): ()
	resolveGroup(self, group).Volume = volume
end

function SoundBank.destroy(self: SoundBank): ()
	self:stopPlaylist(0)
	for _, group in self.groups do
		group:Destroy()
	end
	self.groups = {}
	self.cues = {}
end

return SoundBank
