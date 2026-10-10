--!strict
-- iconplan: pure planning for `forge gen icons`. Selects every creature and egg
-- entry from a pack's assets/procgen.yml, validates the document through
-- procgen.parse, and resolves the icon spec the CLI renders to a .ppm preview.
-- Nothing here touches the filesystem or the network: the painters are pure
-- Luau (core/domain/procgen) and deterministic, so previews are byte-stable.

local procgen = require("./procgen")
local Icons = require("../../../core/domain/procgen/Icons")

local M = {}

-- Version of the icon rendering recipe (this module plus the Icons painters).
-- Bump it whenever a change alters the PPM bytes a job renders to.
M.RECIPE_VERSION = "1"

export type Kind = "creature" | "egg"

export type Job = {
	key: string,
	kind: Kind,
	spec: any,
	size: number,
}

M.SIZE = 128

--- Selects one icon job per creature and per egg in a decoded procgen.yml,
--- sorted by key so re-runs are byte-identical. Colors stay in the raw 0-255
--- form the yml authors; Icons accepts both that and 0..1 tables.
function M.plan(doc: any): ({ Job }?, { string })
	local entries, errors = procgen.parse(doc)
	if #errors > 0 then
		return nil, errors
	end

	local raw: { [string]: any } = {}
	if typeof(doc) == "table" and typeof(doc.assets) == "table" then
		for _, item in doc.assets do
			if typeof(item) == "table" and typeof(item.key) == "string" then
				raw[item.key] = item
			end
		end
	end

	local jobs: { Job } = {}
	for _, entry in entries do
		local source = raw[entry.key]
		if source ~= nil and entry.kind == "creature" then
			table.insert(jobs, {
				key = entry.key,
				kind = "creature",
				spec = {
					archetype = entry.archetype,
					scale = entry.scale,
					body = source.body,
					accent = source.accent,
					eye = source.eye,
					seed = entry.seed,
				},
				size = M.SIZE,
			})
		elseif source ~= nil and entry.archetype == "egg" then
			table.insert(jobs, {
				key = entry.key,
				kind = "egg",
				spec = { scale = entry.scale, body = source.body, accent = source.accent, seed = entry.seed },
				size = M.SIZE,
			})
		end
	end

	table.sort(jobs, function(a, b)
		return a.key < b.key
	end)
	return jobs, {}
end

--- Renders one planned job to a Pixels canvas.
function M.render(job: Job): any
	if job.kind == "creature" then
		return Icons.creature(job.spec, job.size)
	end
	return Icons.egg(job.spec, job.size)
end

return M
