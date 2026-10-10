--!strict
-- Animator: applies Motion samples to procedurally generated creature Models.
-- Client-only. A single RenderStepped connection drives every attached model,
-- sampling relative to the base pivot captured at attach; MeshPart creatures
-- also squash through their original Size. The server (and any non-client
-- context) gets a no-op handle so call sites stay identical.

local RunService = game:GetService("RunService")
local Motion = require(script.Parent.Parent.Parent.domain.procgen.Motion)

local Animator = {}

export type Handle = { stop: () -> () }

type OneShot = { profile: string, start: number }

type Entry = {
	model: Model,
	profile: Motion.Profile,
	seed: number,
	basePivot: CFrame,
	meshPart: MeshPart?,
	baseSize: Vector3?,
	origin: number,
	oneShot: OneShot?,
}

local entries: { [Model]: Entry } = {}
local order: { Entry } = {}
local connection: RBXScriptConnection? = nil

local DUMMY: Handle = { stop = function() end }

local function removeEntry(entry: Entry): ()
	if entries[entry.model] == entry then
		entries[entry.model] = nil
	end
	local index = table.find(order, entry)
	if index ~= nil then
		table.remove(order, index)
	end
end

local function step(): ()
	local now = os.clock()
	for _, entry in table.clone(order) do
		local model = entry.model
		if model.Parent == nil then
			-- The model was destroyed without going through handle.stop() (a map
			-- reload, a round reset). Evict it here so entries/order do not grow
			-- unboundedly and get rescanned every RenderStepped forever.
			removeEntry(entry)
		elseif model.PrimaryPart ~= nil then
			local t = now - entry.origin
			local profile: Motion.Profile = entry.profile
			local oneShot = entry.oneShot
			if oneShot ~= nil then
				local elapsed = now - oneShot.start
				if elapsed >= Motion.HATCH_DURATION then
					entry.oneShot = nil
				end
				profile = oneShot.profile
				t = elapsed / Motion.HATCH_DURATION
			end
			local motion = Motion.sample(profile, t, entry.seed)
			local pivot = entry.basePivot
				* CFrame.new(motion.offset.x, motion.offset.y, motion.offset.z)
				* CFrame.Angles(motion.pitch, motion.yaw, motion.roll)
			model:PivotTo(pivot)
			local meshPart = entry.meshPart
			local baseSize = entry.baseSize
			if meshPart ~= nil and baseSize ~= nil then
				meshPart.Size =
					Vector3.new(baseSize.X * motion.scale.x, baseSize.Y * motion.scale.y, baseSize.Z * motion.scale.z)
			end
		end
	end
end

--- Attaches `model` to the shared animation loop. Returns a handle whose stop()
--- detaches it. Non-client contexts return a no-op handle.
function Animator.attach(model: Model, profile: Motion.Profile, seed: number): Handle
	if not RunService:IsClient() then
		return DUMMY
	end

	local primary = model.PrimaryPart
	local meshPart: MeshPart? = nil
	local baseSize: Vector3? = nil
	if primary ~= nil and primary:IsA("MeshPart") then
		meshPart = primary
		baseSize = primary.Size
	end

	-- Re-attaching the same model must not orphan its previous entry in
	-- `order`: without this, the old entry stays referenced forever (it is no
	-- longer reachable from `entries`, so handle.stop() on the first handle
	-- can never find it to remove it).
	local existing = entries[model]
	if existing ~= nil then
		removeEntry(existing)
	end

	local entry: Entry = {
		model = model,
		profile = profile,
		seed = seed,
		basePivot = model:GetPivot(),
		meshPart = meshPart,
		baseSize = baseSize,
		origin = os.clock(),
		oneShot = nil,
	}
	entries[model] = entry
	table.insert(order, entry)

	if connection == nil then
		connection = RunService.RenderStepped:Connect(step)
	end

	return {
		stop = function()
			removeEntry(entry)
		end,
	}
end

--- Plays a one-shot profile on an attached model, then returns to its loop.
function Animator.play(model: Model, profile: string): ()
	if not RunService:IsClient() then
		return
	end
	local entry = entries[model]
	if entry == nil then
		return
	end
	if profile == "hatch" then
		entry.oneShot = { profile = "hatch", start = os.clock() }
	end
end

return Animator
