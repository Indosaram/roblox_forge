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
