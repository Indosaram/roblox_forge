--!strict
-- WorldDecor: renders the world's scatter decorations on the client.
--
-- The server builds the world and must keep a collidable Part placeholder for
-- every decoration (EditableMesh content does not replicate, so a server-built
-- mesh would be invisible). WorldBuilder tags each placeholder Part with
-- ProcKind/ProcSeed/ProcScale; this module hides the placeholder and places the
-- matching procedural prop pivoted at it, scaled to ProcScale.
--
-- Decor is built with `forceParts = true` so it uses primitive Parts rather than
-- EditableMesh, leaving the client's small live-mesh budget for creatures.

local ProcAssets = require("../../../../core/infra/render/ProcAssets")

-- Decoration kind (from WorldLayout.decorations) -> generated procgen spec key.
local KIND_KEYS: { [string]: string } = {
	rock = "decor-rock",
	tree = "decor-tree",
	crystal = "decor-crystal",
	crate = "decor-crate",
}

export type ProcAssetsSpecs = { [string]: any }

export type Options = {
	worldName: string,
	procAssetsSpecs: ProcAssetsSpecs,
}

local WorldDecor = {}

function WorldDecor.start(opts: Options): ()
	local decorated: { [Instance]: boolean } = {}

	local function decorate(placeholder: BasePart)
		if decorated[placeholder] then
			return
		end
		decorated[placeholder] = true

		local kind = placeholder:GetAttribute("ProcKind")
		if typeof(kind) ~= "string" then
			return
		end
		local key = KIND_KEYS[string.lower(kind)]
		if key == nil then
			return
		end

		local model = ProcAssets.build(opts.procAssetsSpecs, key, placeholder.Name, { forceParts = true })
		if model == nil then
			return
		end

		local procScale = placeholder:GetAttribute("ProcScale")
		if typeof(procScale) == "Vector3" then
			local extents = model:GetExtentsSize()
			local native = math.max(extents.X, extents.Y, extents.Z)
			local target = math.max(procScale.X, procScale.Y, procScale.Z)
			if native > 1e-4 and target > 0 then
				model:ScaleTo(target / native)
			end
		end

		model:PivotTo(placeholder.CFrame)
		model.Parent = placeholder.Parent
		placeholder.Transparency = 1
	end

	local world = workspace:WaitForChild(opts.worldName)

	for _, descendant in world:GetDescendants() do
		if descendant:IsA("BasePart") then
			decorate(descendant)
		end
	end

	world.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			decorate(descendant)
		end
	end)
end

return WorldDecor
