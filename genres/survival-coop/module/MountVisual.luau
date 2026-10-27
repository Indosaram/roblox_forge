--!strict
-- MountVisual: which riders show a mount body, and how that body is dressed and seated.
--
-- The ride itself (speed, carry) is TamingExtension's server state; this module only turns the
-- per-rider species published in the taming snapshot into a visible, physics-inert body. `plan`
-- is pure: the server world diffs the wanted rides against the bodies it has attached and
-- applies the result each Heartbeat, so attach/detach follows mount, dismount, death and leave.
local M = {}

--- Rider HumanoidRootPart -> mount root offset (studs, negative = below) and the HipHeight lift
--- that raises the rider onto the body's back. Measured against the DinosaurRig silhouette (root
--- to sole 3.25 studs) and a standing rider root 3 studs above ground: lifted by 3, the rider root
--- is 6 up and the mount root 2.75 below it puts the mount's feet on the ground.
M.SEAT = table.freeze({ offsetStuds = -2.75, liftStuds = 3 })
M.MODEL_NAME = "ForgeMount"
-- Skinned mounts (B2a) seat the rider on the back over the Spine bone (it starts at the pelvis). The
-- hide sits BACK_PAD of the bone's height above it (gen_creatures.py pelvis radius / pelvis height:
-- theropod 0.25, ceratopsian 0.35, sauropod 0.22), and a straddling rider's root is
-- RIDER_ABOVE_BACK studs above the hide.
M.BACK_PAD, M.RIDER_ABOVE_BACK = 0.27, 1

--- Seat for a skinned mount whose floor is the mount root's bottom face. `rootHeight` is that
--- root's height, `boneAboveFloor` the Spine bone's height over the floor and `standing` the
--- rider root's height over the ground when standing. Returns the mount root offset under the rider
--- root (negative = below) and the HipHeight lift; the lift never goes below zero, so a mount
--- lower than a standing rider keeps its feet on the ground under the rider.
function M.seat(rootHeight: number, boneAboveFloor: number, standing: number): (number, number)
	local riderAboveFloor = boneAboveFloor * (1 + M.BACK_PAD) + M.RIDER_ABOVE_BACK
	local lift = math.max(0, riderAboveFloor - standing)
	return rootHeight / 2 - (standing + lift), lift
end

-- Deployed pets (C4): a following pet body named ForgePet, server-moved toward its owner and
-- tagged so the HUD shell labels it (HudShell.PET_TAG).
M.PET_MODEL_NAME, M.PET_FOLDER, M.PET_TAG = "ForgePet", "ForgePets", "ForgeWorldPet"
M.FOLLOW = table.freeze({ behind = 4, side = 3, slack = 6, teleport = 60, speed = 20 })

--- The wanted pet body per owner from each owner's taming snapshot: the deployed pet unless it is
--- being ridden (the mount body shows it then). Key is "<petId>|<species>" so a swap re-spawns.
function M.pet(taming: any): (string?, boolean)
	local companions = if type(taming) == "table" then taming.companions else nil
	if type(companions) ~= "table" or type(companions.deployed) ~= "string" then
		return nil, false
	end
	local id = companions.deployed
	local pet = if type(companions.pets) == "table" then companions.pets[id] else nil
	if type(pet) ~= "table" or type(pet.species) ~= "string" or companions.ride == id then
		return nil, false
	end
	return id .. "|" .. pet.species, pet.stay == true
end

--- Where a following pet should walk: behind and beside the owner (x, z = owner position, fx, fz =
--- owner facing). nil when already within slack (or staying); `teleport` when it fell too far back.
function M.followGoal(
	ox: number,
	oz: number,
	fx: number,
	fz: number,
	px: number,
	pz: number,
	stay: boolean
): (number?, number?, boolean)
	local dx, dz = px - ox, pz - oz
	local distance = math.sqrt(dx * dx + dz * dz)
	if stay and distance <= M.FOLLOW.teleport * 4 then
		return nil, nil, false
	end
	local length = math.sqrt(fx * fx + fz * fz)
	local ux, uz = if length > 1e-6 then fx / length else 0, if length > 1e-6 then fz / length else -1
	local gx = ox - ux * M.FOLLOW.behind - uz * M.FOLLOW.side
	local gz = oz - uz * M.FOLLOW.behind + ux * M.FOLLOW.side
	if distance > M.FOLLOW.teleport then
		return gx, gz, true
	end
	if distance <= M.FOLLOW.slack then
		return nil, nil, false
	end
	return gx, gz, false
end

export type Plan = { detach: { string }, attach: { { actor: string, species: string } } }

--- Diffs wanted rides (actor -> species) against attached bodies (actor -> species). A species
--- change detaches then re-attaches. Output is ordered by actor id (deterministic).
function M.plan(wanted: { [string]: string }, attached: { [string]: string }): Plan
	local result: Plan = { detach = {}, attach = {} }
	for actor, species in attached do
		if wanted[actor] ~= species then
			table.insert(result.detach, actor)
		end
	end
	for actor, species in wanted do
		if attached[actor] ~= species then
			table.insert(result.attach, { actor = actor, species = species })
		end
	end
	table.sort(result.detach)
	table.sort(result.attach, function(left, right)
		return left.actor < right.actor
	end)
	return result
end

--- The species a taming snapshot says the actor is riding, or nil when not mounted.
function M.species(taming: any): string?
	if type(taming) ~= "table" or not taming.walkSpeedStuds or type(taming.ride) ~= "table" then
		return nil
	end
	local species = taming.ride.species
	return if type(species) == "string" and #species > 0 then species else nil
end

--- The plan key of the actor's ride: the species, plus "@<skin>" when a paid skin dresses it,
--- so a skin change re-attaches the body like a species change does.
function M.look(taming: any): string?
	local species = M.species(taming)
	local skin = if species then taming.ride.skin else nil
	return if type(skin) == "string" and #skin > 0 then (species :: string) .. "@" .. skin else species
end

--- Splits a plan key back into species and optional skin.
function M.parse(key: string): (string, string?)
	local species, skin = string.match(key, "^([^@]+)@(.+)$")
	return species or key, skin
end

--- Makes a wildlife rig a decoration: no Humanoid, scripts or joints to the world, and every
--- part non-colliding, massless and unqueryable so it cannot change the rider's physics.
function M.dress(model: any): any
	model.Name = M.MODEL_NAME
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Humanoid") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			-- Never shadow the rider's own HumanoidRootPart lookups.
			if descendant.Name == "HumanoidRootPart" then
				descendant.Name = "MountRoot"
			end
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end
	return model
end

return M
