--!strict
-- CreatureView: client-side rendering for a collect-raid pack's procgen
-- creatures. Every pack scaffolded from this genre gets this for free so its
-- hatched creatures render as real procgen models instead of the server's
-- placeholder.
--
-- Why client-side: EditableMesh content does not replicate, so a server-built
-- creature model is invisible to real clients (see MeshAdapter). The scaffolded
-- server instead spawns an invisible placeholder (a Part tagged with
-- CreatureKey/ProcSeed attributes, Transparency 1); this module watches for
-- those placeholders, builds the real procgen model from ProcAssets, and swaps
-- it in, then attaches Animator's idle loop and plays the "hatch" pop.
--
-- Live-mesh budget: creatures take MeshAdapter's EditableMesh path (cached by
-- key+seed), so watchCreatures alone can approach the client's ~6-7 live
-- EditableMesh budget; DecorView always forces the Part path so decoration
-- never contends it (see MeshAdapter.MAX_LIVE_MESHES).

local ProcAssets = require("../../../core/infra/render/ProcAssets")
local Animator = require("../../../core/infra/render/Animator")
local Motion = require("../../../core/domain/procgen/Motion")

local CreatureView = {}

export type Specs = { [string]: ProcAssets.Entry }

export type Handle = { stop: () -> () }

local function profileFor(specs: Specs, key: string): Motion.Profile
	local entry = specs[key]
	return Motion.profileFor(if entry ~= nil then entry.archetype else nil)
end

local function seedFor(specs: Specs, key: string): number
	local entry = specs[key]
	if entry ~= nil and type(entry.seed) == "number" then
		return entry.seed
	end
	return 0
end

--- Builds the procgen creature for `key`, pivots it at `placeholder`, attaches
--- the Animator idle loop, and plays the "hatch" pop. Hides the placeholder
--- (Transparency 1) rather than destroying it, since the server may still hold
--- a reference (e.g. for later cleanup). Returns nil if `key` has no spec.
--- May yield: building an EditableMesh yields on the client.
function CreatureView.spawnCreature(placeholder: BasePart, specs: Specs, key: string): (Model?, Handle?)
	local model = ProcAssets.build(specs, key, key)
	if model == nil then
		return nil, nil
	end
	model:PivotTo(placeholder.CFrame)
	model.Parent = placeholder.Parent
	placeholder.Transparency = 1
	local handle = Animator.attach(model, profileFor(specs, key), seedFor(specs, key))
	Animator.play(model, "hatch")
	return model, handle
end

--- Watches `root` (and its future descendants) for creature placeholders: Parts
--- carrying a non-empty string `CreatureKey` attribute. Each placeholder is
--- rendered at most once. Returns a handle whose stop() disconnects the watch;
--- models already built are left in place.
function CreatureView.watchCreatures(root: Instance, specs: Specs): Handle
	local seen: { [Instance]: boolean } = {}

	local function consider(instance: Instance): ()
		if seen[instance] or not instance:IsA("BasePart") then
			return
		end
		local key = instance:GetAttribute("CreatureKey")
		if type(key) ~= "string" or key == "" then
			return
		end
		seen[instance] = true
		task.spawn(function()
			CreatureView.spawnCreature(instance, specs, key)
		end)
	end

	for _, descendant in root:GetDescendants() do
		consider(descendant)
	end
	local connection = root.DescendantAdded:Connect(consider)

	return {
		stop = function()
			connection:Disconnect()
		end,
	}
end

return CreatureView
