--!strict
-- DecorView: client-side rendering for a collect-raid pack's procgen scatter
-- decorations (rocks, trees, crates, ...). WorldBuilder tags every decoration
-- placeholder Part it cannot resolve itself with ProcKind/ProcSeed/ProcScale
-- attributes (see WorldBuilder.buildDecorations); this module watches for them
-- and swaps in the matching procgen prop.
--
-- Always built with forceParts = true so decoration never takes the
-- EditableMesh path: the client's small live-mesh budget (see MeshAdapter,
-- MAX_LIVE_MESHES) stays reserved for CreatureView's hero creatures.

local ProcAssets = require("../../../core/infra/render/ProcAssets")

local DecorView = {}

export type Specs = { [string]: ProcAssets.Entry }

-- Decoration kind (WorldBuilder's Decoration.kind / the ProcKind attribute it
-- sets, e.g. "Rock") -> generated procgen spec key (e.g. "decor-rock").
export type KindKeys = { [string]: string }

export type Handle = { stop: () -> () }

--- Watches `root` for decoration placeholders WorldBuilder tags by default
--- (ProcKind/ProcSeed/ProcScale string+number+Vector3 attributes) and swaps in
--- the matching procgen prop, built with forceParts = true. `kindKeys` maps a
--- decoration's ProcKind (e.g. "Rock") to its procgen.yml key (e.g.
--- "decor-rock"); kinds absent from the map or from `specs` are left as their
--- plain-Part fallback. Each placeholder is decorated at most once.
function DecorView.watchDecor(root: Instance, specs: Specs, kindKeys: KindKeys): Handle
	local decorated: { [Instance]: boolean } = {}

	local function decorate(placeholder: BasePart): ()
		if decorated[placeholder] then
			return
		end
		decorated[placeholder] = true

		local kind = placeholder:GetAttribute("ProcKind")
		if typeof(kind) ~= "string" then
			return
		end
		local key = kindKeys[kind]
		if key == nil then
			return
		end

		local model = ProcAssets.build(specs, key, placeholder.Name, { forceParts = true })
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

	local function consider(instance: Instance): ()
		if instance:IsA("BasePart") then
			decorate(instance)
		end
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

return DecorView
