--!strict
local Forge = game:GetService("ReplicatedStorage"):WaitForChild("Forge")
local Controller = require(Forge.genres["survival-coop"].module.BrawlController)
local Combat = require(Forge.genres["survival-coop"].module.Combat)
local Match = require(Forge.core.domain.brawl.Match)
local Personal = require(Forge.genres["survival-coop"].module.JournalPorts)
local M = {}

function M.new(content: any, _world: any, options: any, session: any, seconds: any, wildlife: any): any
	local combat = content.progressionPolicy.combat
	local players = game:GetService("Players")
	local http = game:GetService("HttpService")
	local personal = Personal.personal(session)
	local spawned: { [string]: any } = {}
	local function rig(actor: string): any
		local player = players:GetPlayerByUserId(tonumber(actor) or 0)
		return if player then player.Character else nil
	end
	local function position(actor: string): any
		local character = rig(actor)
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root then { x = root.Position.X, y = root.Position.Y, z = root.Position.Z } else nil
	end
	local controller = Controller.new({
		store = game:GetService("DataStoreService"):GetDataStore("robango-brawl-v1"),
		lease = game:GetService("MemoryStoreService"):GetSortedMap("robango-brawl-leases-v1"),
		directory = game:GetService("MemoryStoreService"):GetSortedMap("robango-brawl-directory-v1"),
		messaging = game:GetService("MessagingService"),
		topic = "robango-brawl-v1",
		owner = options.sessionId,
		key = "arena:" .. (if game.PrivateServerId ~= "" then game.PrivateServerId else game.JobId),
		matchId = http:GenerateGUID(false),
		policy = content.brawlPolicy,
		leaseSeconds = options.leaseSeconds,
		now = seconds,
		utc = options.now,
		ledger = {
			claim = function(actor: string, state: any, utc: number): any
				local result: any = nil
				local ok, reason = session.personalTransaction(actor, function(raw)
					result = Match.reward(raw.envelope.genres["survival-coop"].data, state, actor, utc)
					return raw
				end)
				return if ok then result else { ok = false, reason = reason }
			end,
		},
		facts = function(actor: string): any
			local data = personal.snapshot(actor)
			return {
				level = if data and data.progression then data.progression.level else 1,
				maxHealth = 100,
				equipment = if data then data.inventory.bag else {},
			}
		end,
		action = function(actor: string, token: string, state: any): any
			local kind, target = string.match(token, "^(%a+):(%d+)$")
			local participant = state.actors[actor]
			local origin = position(actor)
			if not participant or not origin then
				return nil
			end
			if token == "dodge" or token == "guard" then
				return { kind = token, range = 0, millis = math.floor(seconds() * 1000) }
			end
			if kind ~= "melee" then
				return nil
			end
			if not target or not state.actors[target] or target == actor then
				return nil
			end
			local destination = position(target)
			if not destination then
				return nil
			end
			local weapon: any = nil
			for _, item in participant.equipment.items or {} do
				local rule = wildlife.catalog.weapons[item.catalogId]
				if rule then
					weapon = rule
					break
				end
			end
			if not weapon then
				return nil
			end
			return {
				kind = kind,
				target = target,
				range = weapon.rangeStuds,
				millis = math.floor(seconds() * 1000),
				id = http:GenerateGUID(false),
				origin = origin,
				direction = { x = destination.x - origin.x, y = destination.y - origin.y, z = destination.z - origin.z },
				rule = {
					mode = kind,
					windupMillis = combat.windupMillis,
					recoveryMillis = weapon.cooldownMillis,
					range = weapon.rangeStuds,
					facingDot = weapon.facingDot,
					damageMilli = weapon.damageMilli,
					ammo = 0,
				},
			}
		end,
		apply = function(state: any, actor: string, fact: any): any
			local participant = state.actors[actor]
			participant.combat = participant.combat or { attacks = {}, readyAt = 0 }
			participant.defense = participant.defense or Combat.defense()
			if fact.kind == "dodge" or fact.kind == "guard" then
				local duration = if fact.kind == "dodge" then combat.dodgeMillis else combat.guardMillis
				participant.defense = Combat.window(participant.defense, fact.kind, fact.millis, duration)
				participant.defense.guardPermille = combat.guardPermille
				return { ok = true }
			end
			local attack, _, reason = Combat.begin(
				fact.id,
				fact.target,
				fact.rule,
				fact.millis,
				participant.combat.readyAt,
				fact.origin,
				fact.direction,
				0,
				participant.mounted == true
			)
			if not attack then
				return { ok = false, reason = reason }
			end
			participant.combat.readyAt = attack.recoveryUntil
			table.insert(participant.combat.attacks, attack)
			return { ok = true }
		end,
		frame = function(state: any): any
			local frame: any = { connected = {}, positions = {}, sight = {} }
			for actor, participant in state.actors do
				frame.positions[actor] = position(actor)
				frame.connected[actor] = frame.positions[actor] ~= nil
				for _, attack in if participant.combat then participant.combat.attacks else {} do
					local destination = position(attack.target)
					if destination then
						local origin = Vector3.new(attack.origin.x, attack.origin.y, attack.origin.z)
						local delta = Vector3.new(destination.x, destination.y, destination.z) - origin
						local parameters = RaycastParams.new()
						parameters.FilterDescendantsInstances = { rig(actor) }
						local hit = workspace:Raycast(origin, delta, parameters)
						frame.sight[attack.id] = hit == nil or hit.Instance:IsDescendantOf(rig(attack.target))
					end
				end
			end
			return frame
		end,
		publish = function(state: any)
			for actor, participant in state.actors do
				local character = rig(actor)
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if character and state.phase ~= "queue" and participant.alive then
					local previous = spawned[actor]
					if not previous or previous.id ~= state.id or previous.character ~= character then
						local index = assert(table.find(state.order, actor), "BRAWL_PARTICIPANT_ORDER")
						local spawn = content.brawlPolicy.spawns[index]
						character:PivotTo(CFrame.new(spawn.x, spawn.y + 3, spawn.z))
						spawned[actor] = { id = state.id, character = character }
					end
				end
				if humanoid and participant.mounted == false then
					humanoid.Sit = false
				end
			end
		end,
	})
	assert(controller.acquire().ok, "BRAWL_ACQUIRE_FAILED")
	function controller.finish(): any
		local state = controller.snapshot()
		local settled = controller.settle()
		if not settled.ok then
			return settled
		end
		if seconds() >= state.finishedAt + content.brawlPolicy.preparationSeconds then
			return controller.nextMatch(http:GenerateGUID(false))
		end
		return { ok = true }
	end
	return controller
end

return M
