--!strict
-- D2 R12 (personal island): away from the camp ring the home island must not read as bare ground.
-- Every land rank scatters at least MIN_OUTSIDE B1 kit pieces (WorldDressing.HOME_SCATTER) between
-- the camp ring and the coast, none on a pad, plot, structure, camp kit or the dock path, the
-- scatter is seeded by the home seed, and a starter house (a kit with a B3 mesh row) stands
-- beside the camp.
local Content = require("./src/shared/SurvivalContent")
local Dressing = require("./src/server/WorldDressing")
local HomeWorld = require("./src/server/HomeWorld")
local Meshes = require("./src/server/StructureMeshes")
local BiomeKits = require("./src/shared/BiomeKits")
local HomeContent = require("../../core/domain/home/HomeContent")
local Home = require("../../core/domain/home/HomeState")

-- B1 onboarding density: >= 20 mesh vegetation per default-zoom screen; a rank-1 island is one screen.
local MIN_OUTSIDE = 20
-- The camp ring: tall props and scatter stay at least this far from the island centre.
local RING = 24

local function homeLayout(): any
	for _, layout in Content.layouts :: any do
		if layout.id == "rw.home" then
			return layout
		end
	end
	error("no rw.home layout")
end

local function scatter(parts: { any }): { any }
	local out = {}
	for _, part in parts do
		if part.kind == "biome-kit" and string.find(part.id, "home.scatter.", 1, true) == 1 then
			table.insert(out, part)
		end
	end
	return out
end

local function violations(parts: { any }, layout: any): { string }
	local failures = {}
	local boxes = Dressing.homeFootprints(parts)
	for _, piece in scatter(parts) do
		local x, z = piece.position.x, piece.position.z
		if math.sqrt(x * x + z * z) < RING then
			table.insert(failures, piece.id .. " inside the camp ring")
		end
		if Dressing.onHomePath(layout, x, z, 0) then
			table.insert(failures, piece.id .. " on the dock path")
		end
		for _, box in boxes do
			if x >= box.x0 and x <= box.x1 and z >= box.z0 and z <= box.z1 then
				table.insert(failures, piece.id .. " on " .. box.id)
			end
		end
		for _, node in layout.resourceNodes do
			if (x - node.position.x) ^ 2 + (z - node.position.z) ^ 2 < 36 then
				table.insert(failures, piece.id .. " on node " .. node.id)
			end
		end
	end
	return failures
end

local function rowKeys(): { [string]: string }
	local keys = {}
	for _, row in BiomeKits.kits.beach do
		keys[row.key] = row.family
	end
	return keys
end

local cases = {}

cases["home island scatters kit pieces outside the camp ring, off plots and the dock path"] = function()
	local rules = HomeContent.rules(Content)
	local layout = homeLayout()
	local keys = rowKeys()
	for rank in rules.landSizes do
		local home = Home.new("owner", rules, 79)
		home.landRank = rank
		local parts = HomeWorld.plan(Content, home, rules)
		local pieces = scatter(parts)
		local vegetation = 0
		for _, piece in pieces do
			assert(keys[piece.key] == piece.family and piece.kit == "beach", "unknown kit row " .. piece.key)
			if piece.family ~= "rock" and piece.family ~= "clutter" then
				vegetation += 1
			end
		end
		assert(vegetation >= MIN_OUTSIDE, "rank " .. rank .. ": " .. vegetation .. " vegetation outside the camp")
		local failures = violations(parts, layout)
		assert(#failures == 0, "rank " .. rank .. ":\n" .. table.concat(failures, "\n"))
	end
end

cases["placed plots and structures push the scatter off without reshuffling it"] = function()
	local rules = HomeContent.rules(Content)
	local layout = homeLayout()
	local home = Home.new("owner", rules, 79)
	home.landRank = 3
	local before = scatter(HomeWorld.plan(Content, home, rules))
	-- Build on top of the first few scatter pieces.
	for index = 1, 4 do
		local at = before[index].position
		home.structures["plot" .. index] =
			{ kind = "farm-plot", position = { x = at.x, y = 0, z = at.z }, owner = "owner" }
	end
	local parts = HomeWorld.plan(Content, home, rules)
	local failures = violations(parts, layout)
	assert(#failures == 0, table.concat(failures, "\n"))
	local after: { [string]: any } = {}
	for _, piece in scatter(parts) do
		after[piece.id] = piece
	end
	for index = 1, 4 do
		assert(after[before[index].id] == nil, "piece under a placed plot is removed")
	end
	local kept, total = 0, 0
	for _, piece in before do
		local same = after[piece.id]
		if same then
			kept += 1
			assert(same.key == piece.key and same.position.x == piece.position.x, "scatter reshuffled")
		end
	end
	for _ in after do
		total += 1
	end
	assert(total == kept, "no new pieces appear when the player builds")
	assert(kept >= #before - 8, "building removed only the pieces it covers")
end

cases["home scatter is seeded by the home seed"] = function()
	local rules = HomeContent.rules(Content)
	local function signature(seed: number): string
		local out = {}
		for _, piece in scatter(HomeWorld.plan(Content, Home.new("owner", rules, seed), rules)) do
			table.insert(out, string.format("%s@%.3f,%.3f", piece.key, piece.position.x, piece.position.z))
		end
		return table.concat(out, ";")
	end
	assert(signature(79) == signature(79), "same seed, same island")
	assert(signature(79) ~= signature(80), "another seed dresses another island")
end

cases["a starter house with a B3 mesh row stands beside the camp"] = function()
	local rules = HomeContent.rules(Content)
	local home = Home.new("owner", rules, 79)
	local parts = HomeWorld.plan(Content, home, rules)
	local house, x, z, n = false, 0, 0, 0
	for _, part in parts do
		if part.kit == "home.house" then
			house = Meshes.DRESSING[part.kitKind] ~= nil
			x += part.position.x
			z += part.position.z
			n += 1
		end
	end
	assert(house and n > 0, "no starter house kit")
	x, z = x / n, z / n
	local d = math.sqrt(x * x + z * z)
	assert(d <= RING, "starter house is not beside the camp: " .. d)
	-- It leaves the dock path and every pad clear.
	assert(not Dressing.onHomePath(homeLayout(), x, z, 4), "house on the dock path")
	for _, part in parts do
		if part.kind == "starter-pad" or part.kind == "farm-plot" or part.kind == "dock" then
			local box = Dressing.homeFootprints({ part })[1]
			for _, piece in parts do
				if piece.kit == "home.house" then
					local p = piece.position
					assert(
						not (p.x >= box.x0 and p.x <= box.x1 and p.z >= box.z0 and p.z <= box.z1),
						"house piece " .. piece.id .. " on " .. part.id
					)
				end
			end
		end
	end
end

cases["NEGATIVE: a scatter piece on the dock path or a pad is reported"] = function()
	local rules = HomeContent.rules(Content)
	local layout = homeLayout()
	local parts = HomeWorld.plan(Content, Home.new("owner", rules, 79), rules)
	local probe = table.clone(parts)
	table.insert(probe, {
		id = "home.scatter.mutant",
		kind = "biome-kit",
		position = { x = 0, y = 0, z = 26 },
	})
	assert(#violations(probe, layout) > 0, "dock path mutation must fail")
	local pad: any = nil
	for _, part in parts do
		if part.kind == "starter-pad" then
			pad = part
		end
	end
	probe = table.clone(parts)
	table.insert(probe, { id = "home.scatter.mutant", kind = "biome-kit", position = table.clone(pad.position) })
	assert(#violations(probe, layout) > 0, "pad mutation must fail")
end

return cases
