--!strict
-- Audio: client-side audio coverage for collect-raid packs. Listens to the
-- existing remotes and player UI to score every action, loops the music
-- playlist with a crossfade, and layers a low ambience bed. Reads state only;
-- no gameplay logic is changed. Cue definitions and Notify-text classifiers
-- come from `opts` so the genre never depends on a pack's copy.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundBank = require("../../../../core/infra/audio/SoundBank")

export type CreatureConfig = { rarity: string, [string]: any }

export type NotifyClassifiers = {
	isRareHatch: (text: string) -> boolean,
	isHatchFailure: (text: string) -> boolean,
	isRaidText: (text: string) -> boolean,
}

export type PromptClassifiers = {
	isHatchAction: (actionText: string) -> boolean,
	isRaidAction: (actionText: string) -> boolean,
}

export type Options = {
	remotes: {
		StateChanged: RemoteEvent,
		Notify: RemoteEvent,
		SiegeState: RemoteEvent,
		RaidReplay: RemoteEvent,
		TutorialState: RemoteEvent,
	},
	cues: { [string]: SoundBank.Cue },
	creatures: { [string]: CreatureConfig },
	rarityRank: { [string]: number },
	notifyClassifiers: NotifyClassifiers,
	promptClassifiers: PromptClassifiers,
	musicTracks: { explore: string, siege: string },
	teamRivals: { [string]: string },
}

local Audio = {}

function Audio.start(opts: Options): ()
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")

	local StateChanged = opts.remotes.StateChanged
	local Notify = opts.remotes.Notify
	local SiegeState = opts.remotes.SiegeState
	local RaidReplayRemote = opts.remotes.RaidReplay
	local TutorialState = opts.remotes.TutorialState

	local bank = SoundBank.new({ Music = 0.35, SFX = 0.6, UI = 0.5 })
	for name, cue in opts.cues do
		bank:define(name, cue)
	end
	task.spawn(function()
		bank:preload()
	end)

	-- Looping ambience bed (wind drone plus a sparse high layer) at low volume.
	bank:play("ambienceWind")
	bank:play("ambienceBirds")

	-- Music: explore loops by default; the siege track takes over only while the
	-- siege phase is active (switched in the SiegeState handler). The Music group
	-- volume (0.35) is the playlist level and the crossfade is two seconds.
	bank:playPlaylist({ opts.musicTracks.explore }, { crossfade = 2, volume = 1 })

	-- Raid stinger shared by the server replay event and the team-vault diff; the
	-- dedupe window keeps a single raid from playing it twice.
	local lastRaidCueAt = 0
	local function playRaid(): ()
		local now = os.clock()
		if now - lastRaidCueAt < 0.5 then
			return
		end
		lastRaidCueAt = now
		bank:play("raid")
	end

	-- UI clicks: every button under PlayerGui, now and in the future.
	local function hookButton(instance: Instance): ()
		if not instance:IsA("GuiButton") then
			return
		end
		instance.Activated:Connect(function()
			bank:play("uiClick")
		end)
	end

	for _, descendant in playerGui:GetDescendants() do
		hookButton(descendant)
	end
	playerGui.DescendantAdded:Connect(hookButton)

	-- Proximity prompts (server-built incubators and vault crates).
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, _player: Player)
		if opts.promptClassifiers.isHatchAction(prompt.ActionText) then
			bank:play("promptHatch")
		elseif opts.promptClassifiers.isRaidAction(prompt.ActionText) then
			bank:play("promptRaid")
		else
			bank:play("uiClick")
		end
	end)

	-- Rarity ordering lets a snapshot diff tell a merge (several lower-rarity
	-- creatures replaced by one higher-rarity creature) from a plain hatch.
	local function rarityRank(id: string): number
		local config = opts.creatures[id]
		if config == nil then
			return 0
		end
		return opts.rarityRank[config.rarity] or 0
	end

	local function countByIds(ids: any): { [string]: number }
		local counts: { [string]: number } = {}
		if type(ids) ~= "table" then
			return counts
		end
		for _, id in ids do
			if type(id) == "string" then
				counts[id] = (counts[id] or 0) + 1
			end
		end
		return counts
	end

	-- State changes: coin ticks, big coin gains, new sources placed, hatches, merges.
	local lastCoins: number? = nil
	local lastSources: number? = nil
	local lastCreatureList: { string }? = nil
	local lastQuestClaimed: { [string]: boolean }? = nil
	local lastCoinAt = 0

	StateChanged.OnClientEvent:Connect(function(snapshot: any)
		if type(snapshot) ~= "table" then
			return
		end

		local coins = snapshot.coins
		if type(coins) == "number" then
			if lastCoins ~= nil and coins > lastCoins then
				local now = os.clock()
				if coins - lastCoins > 100 then
					lastCoinAt = now
					bank:play("coinBig")
				elseif now - lastCoinAt >= 0.3 then
					lastCoinAt = now
					bank:play("coin")
				end
			end
			lastCoins = coins
		end

		local sourceCount = 0
		for _, incubator in snapshot.incubators or {} do
			if type(incubator) == "table" and incubator.sourceId ~= nil then
				sourceCount += 1
			end
		end
		if lastSources ~= nil and sourceCount > lastSources then
			bank:play("place")
		end
		lastSources = sourceCount

		-- Creature diff: a merge fuses >=2 lower-rarity creatures into one
		-- higher-rarity creature, so the count drops and a higher rarity appears;
		-- a hatch only ever adds one. Both cues reuse the verified ids.
		local creatureIds: { string } = {}
		for _, id in snapshot.creatures or {} do
			if type(id) == "string" then
				table.insert(creatureIds, id)
			end
		end
		local creatureCounts = countByIds(creatureIds)
		if lastCreatureList ~= nil then
			local previous = countByIds(lastCreatureList)
			local removed = 0
			local removedTopRank = 0
			for id, count in previous do
				local gone = count - (creatureCounts[id] or 0)
				if gone > 0 then
					removed += gone
					removedTopRank = math.max(removedTopRank, rarityRank(id))
				end
			end
			local added = 0
			local addedHigher = false
			for id, count in creatureCounts do
				local gained = count - (previous[id] or 0)
				if gained > 0 then
					added += gained
					if rarityRank(id) > removedTopRank then
						addedHigher = true
					end
				end
			end
			if removed >= 2 and addedHigher then
				bank:play("mergeLow")
				bank:play("mergeHigh")
			elseif removed == 0 and added > 0 then
				bank:play("hatch")
			end
		end
		lastCreatureList = creatureIds

		-- Quest claim: a claimed flag flipping false -> true gets a dedicated cue.
		local claimedNow: { [string]: boolean } = {}
		for _, quest in snapshot.quests or {} do
			if type(quest) == "table" and type(quest.id) == "string" then
				local claimed = quest.claimed == true
				claimedNow[quest.id] = claimed
				if claimed and lastQuestClaimed ~= nil and lastQuestClaimed[quest.id] ~= true then
					bank:play("questClaim")
				end
			end
		end
		lastQuestClaimed = claimedNow
	end)

	-- Notify: rare hatch fanfare, plus a failure blip for rejected actions.
	Notify.OnClientEvent:Connect(function(text: any)
		if type(text) ~= "string" then
			return
		end
		if opts.notifyClassifiers.isRareHatch(text) then
			bank:play("fanfare")
		elseif opts.notifyClassifiers.isHatchFailure(text) then
			bank:play("error")
		elseif opts.notifyClassifiers.isRaidText(text) then
			-- Raid failures come back as "Raid: <reason>" or the own-vault notice.
			bank:play("raidMiss")
		end
	end)

	-- Local-only notifications (HUD raid misses): a distinct low miss blip. The
	-- HUD fires LocalNotify because a rejected raid never reaches the server's
	-- Notify broadcast.
	local localNotify = ReplicatedStorage:FindFirstChild("LocalNotify")
	if localNotify == nil or not localNotify:IsA("BindableEvent") then
		local created = Instance.new("BindableEvent")
		created.Name = "LocalNotify"
		created.Parent = ReplicatedStorage
		localNotify = created
	end
	(localNotify :: BindableEvent).Event:Connect(function(_text: any)
		bank:play("raidMiss")
	end)

	-- Siege phase transitions: horn on start, low blip on end, and the music
	-- playlist swaps to the siege track only while the phase is active.
	local lastSiegePhase: string? = nil
	-- The default explore playlist is already playing, so start the tracker on it.
	local lastMusicTrack: string? = opts.musicTracks.explore
	local lastVaultCounts: { [string]: number }? = nil

	local function setMusicTrack(track: string): ()
		if track == lastMusicTrack then
			return
		end
		lastMusicTrack = track
		bank:playPlaylist({ track }, { crossfade = 2, volume = 1 })
	end

	SiegeState.OnClientEvent:Connect(function(info: any)
		if type(info) ~= "table" or type(info.phase) ~= "string" then
			return
		end
		local phase = info.phase
		if lastSiegePhase ~= nil and phase ~= lastSiegePhase then
			if phase == "active" then
				bank:play("siegeStart")
			else
				bank:play("siegeEnd")
			end
		end
		lastSiegePhase = phase
		setMusicTrack(if phase == "active" then opts.musicTracks.siege else opts.musicTracks.explore)

		-- A raid is the only thing that moves creatures between team vaults: the
		-- attacker's vault rises while the defender's falls. That is the reliable
		-- "stolen creatures added" signal; playRaid dedupes it against RaidReplay.
		local counts = info.vaultCounts
		if type(counts) == "table" then
			local team = player.Team
			local teamName = if team ~= nil then team.Name else nil
			if lastVaultCounts ~= nil and phase == "active" and teamName ~= nil then
				local ownNow = counts[teamName]
				local ownBefore = lastVaultCounts[teamName]
				if type(ownNow) == "number" and type(ownBefore) == "number" and ownNow > ownBefore then
					for name, count in counts do
						local before = lastVaultCounts[name]
						if
							name ~= teamName
							and type(count) == "number"
							and type(before) == "number"
							and count < before
						then
							playRaid()
							break
						end
					end
				end
			end
			local copy: { [string]: number } = {}
			for name, count in counts do
				if type(name) == "string" and type(count) == "number" then
					copy[name] = count
				end
			end
			lastVaultCounts = copy
		end
	end)

	-- Raid replay: impact stinger when the camera swoop begins (moved > 0).
	RaidReplayRemote.OnClientEvent:Connect(function(data: any)
		if type(data) ~= "table" then
			return
		end
		playRaid()
	end)

	-- Tutorial: a step chime whenever the server advances the step.
	local lastTutorialStep: string? = nil
	TutorialState.OnClientEvent:Connect(function(info: any)
		if type(info) ~= "table" or type(info.step) ~= "string" then
			return
		end
		if lastTutorialStep ~= nil and info.step ~= lastTutorialStep and info.step ~= "complete" then
			bank:play("tutorial")
		end
		lastTutorialStep = info.step
	end)

	-- Robux purchase success: fanfare for both developer products and game passes.
	MarketplaceService.PromptProductPurchaseFinished:Connect(
		function(_userId: number, _productId: number, purchased: boolean)
			if purchased then
				bank:play("fanfare")
			end
		end
	)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(_purchasedBy: Player, _gamePassId: number, purchased: boolean)
			if purchased then
				bank:play("fanfare")
			end
		end
	)

	print("[Audio] sound bank ready")
end

return Audio
