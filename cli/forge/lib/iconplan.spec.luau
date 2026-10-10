--!strict
-- Specs for iconplan: which procgen.yml entries become icons, the fixed preview
-- size, error pass-through, and rendering at the planned size.

local iconplan = require("./iconplan")

local function doc(assets: { any }): any
	return { assets = assets }
end

local CREATURE: any = {
	key = "pyro-pup",
	kind = "creature",
	archetype = "quad",
	scale = 1,
	body = { 235, 110, 40 },
	accent = { 255, 200, 60 },
	eye = { 255, 255, 180 },
	seed = 101,
}

local EGG: any = {
	key = "ember-egg",
	kind = "prop",
	archetype = "egg",
	scale = 1,
	body = { 240, 120, 40 },
	accent = { 255, 210, 90 },
	seed = 201,
}

local CRYSTAL: any = {
	key = "shard",
	kind = "prop",
	archetype = "crystal",
	scale = 1,
	body = { 40, 120, 220 },
	accent = { 140, 230, 255 },
	seed = 301,
}

local function assertNonEmpty(canvas: any, label: string): ()
	local painted = false
	for i = 4, #canvas.data, 4 do
		if canvas.data[i] > 0 then
			painted = true
			break
		end
	end
	assert(painted, label .. " must paint at least one pixel")
end

return {
	["plan selects every creature and egg and skips other props"] = function()
		local jobs, errors = iconplan.plan(doc({ CREATURE, EGG, CRYSTAL }))
		assert(#errors == 0, "expected no errors, got " .. table.concat(errors, "; "))
		local planned = jobs :: { iconplan.Job }
		assert(#planned == 2, "one creature plus one egg")
		assert(planned[1].key == "ember-egg" and planned[1].kind == "egg", "jobs are sorted by key")
		assert(planned[2].key == "pyro-pup" and planned[2].kind == "creature", "the creature follows")
		assert(planned[1].size == 128 and planned[2].size == 128, "previews are 128px")
		assert(planned[1].spec.seed == 201, "the egg spec keeps its seed")
	end,

	["plan reports parse errors from procgen.yml"] = function()
		local bad = {
			key = "mystery",
			kind = "creature",
			archetype = "dragon",
			scale = 1,
			body = { 0, 0, 0 },
			accent = { 0, 0, 0 },
			eye = { 0, 0, 0 },
			seed = 1,
		}
		local jobs, errors = iconplan.plan(doc({ bad }))
		assert(jobs == nil and #errors > 0, "an invalid document yields errors and no jobs")
	end,

	["render paints a non-empty icon at the planned size"] = function()
		local jobs = iconplan.plan(doc({ CREATURE, EGG })) :: { iconplan.Job }
		assert(#jobs == 2, "expected two jobs")
		for _, job in jobs do
			local canvas = iconplan.render(job)
			assert(canvas.width == job.size and canvas.height == job.size, job.key .. " icon is the planned size")
			assertNonEmpty(canvas, job.key .. " icon")
		end
	end,
}
