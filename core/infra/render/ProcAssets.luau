--!strict
-- ProcAssets: the runtime bridge from a generated specs table
-- (games/<pack>/src/shared/ProcAssets.luau, built by `forge gen procedural`) to
-- a Roblox Model. It re-runs the same pure core generators the CLI measured, so
-- the built mesh and its triangle count are deterministic and keyless, then
-- hands the mesh data to MeshAdapter for EditableMesh/Part conversion.
--
-- Routing: creatures take MeshAdapter's EditableMesh path; eggs and props pass
-- `forceParts = true` so they always build from primitive Parts, keeping the
-- client's handful of live EditableMeshes reserved for the hero creatures.
--
-- Both requires are instance-path relative, matching how MeshAdapter sits under
-- core/infra/render and Creature/Prop under core/domain/procgen at runtime.

local MeshAdapter = require(script.Parent.MeshAdapter)
local Creature = require(script.Parent.Parent.Parent.domain.procgen.Creature)
local Prop = require(script.Parent.Parent.Parent.domain.procgen.Prop)

local ProcAssets = {}

export type Entry = {
	kind: string,
	archetype: string,
	spec: any,
	seed: number,
	triangleCount: number,
}

export type BuildOpts = {
	-- Force the primitive Part path instead of EditableMesh. Set for eggs and
	-- decor props so the client's ~7-live-EditableMesh budget stays free for
	-- creatures.
	forceParts: boolean?,
}

--- Builds the Model for `key` from a generated specs table. Returns nil when
--- the key is absent, unknown, or not a creature/prop, so callers can fall back
--- to their hand-authored model.
function ProcAssets.build(specsTable: { [string]: Entry }, key: string, name: string?, opts: BuildOpts?): Model?
	local entry = specsTable[key]
	if entry == nil then
		return nil
	end

	local meshData: any
	if entry.kind == "creature" then
		meshData = Creature.generate(entry.spec, entry.seed)
	elseif entry.kind == "prop" then
		meshData = Prop.generate(entry.archetype :: any, entry.spec, entry.seed)
	else
		return nil
	end

	return MeshAdapter.toInstance(meshData, name or key, {
		cacheKey = key .. ":" .. tostring(entry.seed),
		forceParts = if opts ~= nil then opts.forceParts else nil,
	})
end

return ProcAssets
