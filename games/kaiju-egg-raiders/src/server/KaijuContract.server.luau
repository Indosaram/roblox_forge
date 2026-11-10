--!strict
-- KaijuContract.server.luau: the Studio contract surface for a pack whose genre
-- runtime predates it.
--
-- The collect-raid genre module publishes `ServerStorage.ForgeQA`, the bindable
-- Open Cloud Luau Execution and the legacy playtest runner drive. The Studio QA
-- driver instead requires the core contract pair (`ReplicatedStorage.ForgeState`
-- event + `ForgeAction` function) and refuses to run any step without it, so a
-- pack built on this genre cannot execute a Studio scenario at all.
--
-- This bridges the two over the SAME runtime: state is read from the genre's own
-- ForgeQA bindable (which reads the live player state it holds), and actions are
-- dispatched through the pack's real remotes, so a passing scenario exercises the
-- handlers the buttons call rather than a parallel contract runtime. Nothing here
-- duplicates gameplay logic; it is an adapter, and it does not touch core/genre.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

-- The genre runtime boots asynchronously and may not have published its surface
-- yet; waiting keeps this file order-independent instead of racing its require.
local legacyQa = ServerStorage:WaitForChild("ForgeQA", 60)
assert(legacyQa ~= nil and legacyQa:IsA("BindableFunction"), "genre ForgeQA surface missing")

-- The genre module publishes ServerStorage.ForgeQA as a bare BindableFunction. The
-- Studio driver's preflight requires that name to be a Folder carrying revision /
-- snapshot / dispatch / save, so a bare function makes every scenario fail at step 1
-- with "revision is not a valid member". Renaming the genre surface keeps its Open
-- Cloud contract intact (nothing calls it by that hardcoded path except external
-- Luau Execution) and frees the name for the contract folder below.
legacyQa.Name = "ForgeQALegacy"

local revision = 0
local ForgeAction = Instance.new("RemoteFunction")
ForgeAction.Name = "ForgeAction"
local ForgeState = Instance.new("RemoteEvent")
ForgeState.Name = "ForgeState"

-- The genre bindable answers `snapshot` with { owned, coins, vault }; the contract
-- snapshot is a per-genre table, so the shape is wrapped rather than faked. Only
-- values the genre surface actually answers are reported here: inventing a
-- hatch-ready count from a key it does not expose would be a fake reading.
local function snapshotFor(): any
	local counts = legacyQa:Invoke("snapshot")
	local owned = if type(counts) == "table" then counts.owned or 0 else 0
	local coins = if type(counts) == "table" then counts.coins or 0 else 0
	local vault = if type(counts) == "table" then counts.vault or 0 else 0
	return {
		balance = coins,
		owned = owned,
		vault = vault,
		coins = coins,
	}
end

local function pushState(player: Player): ()
	revision += 1
	ForgeState:FireClient(player, { snapshots = { ["collect-raid"] = snapshotFor() }, revision = revision })
end

ForgeAction.OnServerInvoke = function(player: Player, id: any, _args: any): any
	-- A nil id is the contract's snapshot read: push fresh state, then ack.
	if id == nil then
		pushState(player)
		return { ok = true }
	end
	-- This adapter deliberately declares no gameplay actions. A server cannot reach the
	-- client remote handlers, and calling BuyEgg/HatchEgg from here would invoke a
	-- RemoteFunction whose OnServerInvoke this process owns, which the engine refuses.
	-- Scenarios drive real gameplay by clicking the real HUD; this surface only reads
	-- state, so a passing run cannot have been produced by a shortcut.
	return { ok = false, reason = "READ_ONLY_SURFACE" }
end

ForgeAction.Parent = ReplicatedStorage
ForgeState.Parent = ReplicatedStorage

-- The contract folder the Studio driver preflights. `snapshot` reads the live genre
-- state; `dispatch` is not offered because there is no honest server-side path to the
-- pack's gameplay handlers from here, and a stub that returned success would let a
-- scenario pass without the product working.
local qa = Instance.new("Folder")
qa.Name = "ForgeQA"
local changed = Instance.new("BindableEvent")
changed.Name, changed.Parent = "StateChanged", qa
local function bind(name: string, callback: (...any) -> ...any)
	local fn = Instance.new("BindableFunction")
	fn.Name, fn.OnInvoke, fn.Parent = name, callback, qa
end
bind("revision", function()
	return revision
end)
bind("snapshot", function(_genre: string, _playerId: string)
	return snapshotFor()
end)
bind("save", function(_playerId: string)
	-- The genre runtime persists through its own profile store on leave; there is no
	-- pack-level save hook to call, so this reports the honest state rather than
	-- claiming a save that did not happen.
	return { ok = false, reason = "NO_PACK_SAVE_HOOK" }
end)
qa.Parent = ServerStorage
