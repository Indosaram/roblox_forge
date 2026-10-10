--!strict
-- CollectRaid: genre coordinator for collect-and-raid games. Owns one core Vault
-- per team, wraps the core Siege windows, and reports events through hooks.

local Siege = require("../../../core/domain/state/Siege")
local Vault = require("../../../core/domain/economy/Vault")

local CollectRaid = {}
CollectRaid.__index = CollectRaid

export type CollectCtx = { team: string, itemId: string, raidable: boolean }
export type RaidCtx = { attacker: string, defender: string, moved: number }
export type SiegePhaseCtx = { phase: Siege.Phase, secondsLeft: number }

export type Hooks = {
	OnCollect: ((CollectCtx) -> ())?,
	OnRaid: ((RaidCtx) -> ())?,
	OnSiegePhase: ((SiegePhaseCtx) -> ())?,
}

export type Config = {
	teams: { string },
	siege: { period: number, duration: number, maxTake: number },
}

export type CollectRaid = typeof(setmetatable(
	{} :: {
		_vaults: { [string]: Vault.Vault },
		_teams: { string },
		_siege: Siege.Schedule,
		_maxTake: number,
		_lastPhase: Siege.Phase?,
		_hooks: Hooks,
	},
	CollectRaid
))

local function checkMaxTake(maxTake: number): ()
	if type(maxTake) ~= "number" or maxTake ~= maxTake or maxTake < 0 or maxTake == math.huge or maxTake % 1 ~= 0 then
		error("invalid maxTake")
	end
end

local function vaultFor(self: CollectRaid, team: string, label: string): Vault.Vault
	if type(team) ~= "string" or team == "" then
		error("invalid " .. label)
	end
	local vault = self._vaults[team]
	if vault == nil then
		error("unknown " .. label)
	end
	return vault
end

function CollectRaid.new(config: Config, hooks: Hooks?): CollectRaid
	if type(config) ~= "table" then
		error("invalid config")
	end
	local teams = config.teams
	if type(teams) ~= "table" then
		error("invalid teams")
	end

	local vaults: { [string]: Vault.Vault } = {}
	local ordered: { string } = {}
	for _, team in teams do
		if type(team) ~= "string" or team == "" then
			error("invalid team")
		end
		if vaults[team] ~= nil then
			error("duplicate team")
		end
		vaults[team] = Vault.new()
		table.insert(ordered, team)
	end

	local siege = config.siege
	if type(siege) ~= "table" then
		error("invalid siege")
	end
	local schedule = Siege.new(siege.period, siege.duration)
	checkMaxTake(siege.maxTake)

	local resolvedHooks: Hooks = hooks or {}
	local self = setmetatable({
		_vaults = vaults,
		_teams = ordered,
		_siege = schedule,
		_maxTake = siege.maxTake,
		_lastPhase = nil,
		_hooks = resolvedHooks,
	}, CollectRaid)
	return self
end

-- Deposits an item into the team's vault and reports it through OnCollect.
function CollectRaid.collect(self: CollectRaid, team: string, itemId: string, raidable: boolean): ()
	local vault = vaultFor(self, team, "team")
	Vault.deposit(vault, itemId, raidable)
	local hook = self._hooks.OnCollect
	if hook ~= nil then
		hook({ team = team, itemId = itemId, raidable = raidable })
	end
end

-- Flips every currently non-raidable item in the team's vault to raidable, and
-- returns how many changed. Backs a temporary lock (e.g. a pass that deposits
-- "locked until the next siege"): the lock is meant to last only until the
-- siege window it was deposited before actually opens, not forever, so the
-- caller invokes this once per team when that window opens (e.g. from
-- OnSiegePhase firing "active"). Vault itself has no unlock: this genre
-- coordinator owns `_vaults` directly and is the one place allowed to flip an
-- egg's raidable flag after deposit.
function CollectRaid.releaseLocked(self: CollectRaid, team: string): number
	local vault = vaultFor(self, team, "team")
	local released = 0
	for _, egg in vault._eggs do
		if not egg.raidable then
			egg.raidable = true
			released += 1
		end
	end
	return released
end

-- Wraps the core siege schedule; OnSiegePhase fires only when the phase changes.
function CollectRaid.phase(self: CollectRaid, elapsed: number): (Siege.Phase, number)
	local phase: Siege.Phase, secondsLeft: number = Siege.phase(self._siege, elapsed)
	if phase ~= self._lastPhase then
		self._lastPhase = phase
		local hook = self._hooks.OnSiegePhase
		if hook ~= nil then
			hook({ phase = phase, secondsLeft = secondsLeft })
		end
	end
	return phase, secondsLeft
end

-- Moves up to siege.maxTake raidable items from the defender to the attacker.
-- Returns (moved, nil) on success and (0, reason) when the raid is refused.
function CollectRaid.raid(
	self: CollectRaid,
	attackerTeam: string,
	defenderTeam: string,
	elapsed: number,
	isShielded: boolean?
): (number, string?)
	local attacker = vaultFor(self, attackerTeam, "attacker team")
	local defender = vaultFor(self, defenderTeam, "defender team")
	local phase = Siege.phase(self._siege, elapsed)
	if phase ~= "active" then
		return 0, "siege not active"
	end
	if isShielded then
		return 0, "shielded"
	end
	if attackerTeam == defenderTeam then
		return 0, "same team"
	end

	local moved = Vault.raid(attacker, defender, self._maxTake)
	-- OnRaid means a raid actually moved something; a successful window with an
	-- empty defender vault is not an event a consumer's "a raid happened" hook
	-- should have to filter out itself.
	if moved > 0 then
		local hook = self._hooks.OnRaid
		if hook ~= nil then
			hook({ attacker = attackerTeam, defender = defenderTeam, moved = moved })
		end
	end
	return moved, nil
end

-- Returns each team's raidable item count.
function CollectRaid.counts(self: CollectRaid): { [string]: number }
	local result: { [string]: number } = {}
	for _, team in self._teams do
		result[team] = Vault.count(self._vaults[team], true)
	end
	return result
end

-- Returns each team's total item count, raidable and locked alike. Lets a spec
-- or liveops dashboard confirm a deposit landed even when it is non-raidable,
-- which `counts()` (raidable-only) cannot see.
function CollectRaid.totalCounts(self: CollectRaid): { [string]: number }
	local result: { [string]: number } = {}
	for _, team in self._teams do
		result[team] = Vault.count(self._vaults[team])
	end
	return result
end

return CollectRaid
