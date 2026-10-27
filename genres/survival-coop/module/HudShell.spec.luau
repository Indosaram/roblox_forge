--!strict
-- HudShell regions against ui-spec.md section 5 (Robango A4, G5): the spec's pixel rects at the
-- 2400x1080 phone (SM-N981N, scale 2.625, side inset 32, top bar 58 logical) and 1920x1080 PC
-- (top bar 58), all inside the safe area, below the top bar and never overlapping.
local Shell = require("./HudShell")

local REGIONS = { "vitals", "chips", "tracker", "status", "minimap", "coords", "quest", "row", "cluster" }

-- Viewports in gui (logical) px: { width, height, topClear, touch, physical scale, side inset }.
local PHONE: { any } = { 850, 411, 58, true, 2.625, 32 }
local PC: { any } = { 1920, 1080, 58, false, 1, 0 }

local function physical(r: any, view: any): { number }
	local s, side = view[5], view[6]
	return { (r.x + side) * s, r.y * s, r.width * s, r.height * s }
end

local function near(id: string, got: { number }, want: { number }, slack: number)
	for i = 1, 4 do
		assert(
			math.abs(got[i] - want[i]) <= slack,
			string.format(
				"%s[%d] = %.1f, spec %d (got %.0f,%.0f %.0fx%.0f)",
				id,
				i,
				got[i],
				want[i],
				got[1],
				got[2],
				got[3],
				got[4]
			)
		)
	end
end

local function check(width: number, height: number, topClear: number, touch: boolean)
	local regions = Shell.regions(width, height, topClear, touch)
	for _, id in REGIONS do
		assert(Shell.inside(regions[id], width, height, topClear), string.format("%s inside %dx%d", id, width, height))
	end
	for i, a in REGIONS do
		for j = i + 1, #REGIONS do
			local b = REGIONS[j]
			assert(
				not Shell.overlaps(regions[a], regions[b]),
				string.format("%s overlaps %s at %dx%d", a, b, width, height)
			)
		end
	end
	for i, a in Shell.SLOT_ORDER do
		local token = regions.tokens[a]
		assert(Shell.inside(token, width, height, topClear), a .. " token inside")
		if touch then
			assert(token.width >= Shell.MIN_TOUCH and token.height >= Shell.MIN_TOUCH, a .. " touch size")
		end
		for j = i + 1, #Shell.SLOT_ORDER do
			assert(
				not Shell.circlesOverlap(token, regions.tokens[Shell.SLOT_ORDER[j]]),
				a .. " token overlaps " .. Shell.SLOT_ORDER[j]
			)
		end
	end
	return regions
end

local function flags(over: any): any
	local base = {
		combat = false,
		building = false,
		interact = true,
		dodge = true,
		guard = true,
		stance = true,
		attack = false,
		shoot = false,
		mount = false,
		skills = true,
	}
	for key, value in over do
		base[key] = value
	end
	return base
end

return {
	["regions match ui-spec section 5 at 1920x1080 PC"] = function()
		local r = check(PC[1], PC[2], PC[3], PC[4])
		near("vitals", physical(r.vitals, PC), { 20, 78, 450, 123 }, 2)
		near("chips", physical(r.chips, PC), { 20, 216, 409, 72 }, 2)
		near("minimap", physical(r.minimap, PC), { 1664, 78, 225, 225 }, 2)
		near("coords", physical(r.coords, PC), { 1685, 308, 184, 41 }, 2)
		near("quest", physical(r.quest, PC), { 1389, 365, 501, 123 }, 2)
		near("status", physical(r.status, PC), { 551, 222, 818, 102 }, 2)
		assert(r.arcScale == 1, "PC tide arc at the spec radii")
		-- The spec's own tide arc puts O2 (0.42H at 70 degrees) a little above its 0.62H region line, so
		-- the check is the arc itself: every slot centre at its spec radius and angle from the corner.
		for slot, token in r.tokens do
			local spec = Shell.SLOTS[slot]
			local cx, cy = token.x + token.width / 2, token.y + token.height / 2
			local h = 1080 - 58
			local wantX = 1920 - spec[1] * h * math.cos(math.rad(spec[2]))
			local wantY = 1080 - spec[1] * h * math.sin(math.rad(spec[2]))
			assert(math.abs(cx - wantX) <= 1 and math.abs(cy - wantY) <= 1, slot .. " on the spec arc")
			assert(token.y >= r.quest.y + r.quest.height, slot .. " below the quest card")
		end
		local row = physical(r.row, PC)
		assert(
			row[1] >= 18 and row[2] >= 976 and row[1] + row[3] <= 543 and row[2] + row[4] <= 1062,
			"row inside the spec region"
		)
	end,

	["regions match ui-spec section 5 at 2400x1080 phone"] = function()
		local r = check(PHONE[1], PHONE[2], PHONE[3], PHONE[4])
		-- Logical px round to whole numbers, so one logical px is 2.625 physical: slack 4.
		near("vitals", physical(r.vitals, PHONE), { 103, 171, 408, 111 }, 4)
		near("chips", physical(r.chips, PHONE), { 103, 296, 371, 65 }, 4)
		near("minimap", physical(r.minimap, PHONE), { 2084, 171, 204, 204 }, 4)
		near("coords", physical(r.coords, PHONE), { 2103, 380, 167, 37 }, 4)
		near("quest", physical(r.quest, PHONE), { 1834, 431, 455, 111 }, 4)
		local row = physical(r.row, PHONE)
		assert(row[1] >= 100 and row[1] + row[3] <= 579 and row[2] + row[4] <= 1064, "row inside the spec region")
		-- Spec pt token sizes overlap on the spec radii at H=353: tokens shrink to the 44 px floor and
		-- the arc widens by the smallest step that parts them (documented deviation from the spec).
		assert(r.arcScale <= 1.2, "phone tide arc scale " .. r.arcScale)
		local c = physical(r.cluster, PHONE)
		assert(c[1] + c[3] <= 2400 - 32 * 2.625 + 1 and c[2] + c[4] <= 1080, "cluster in the bottom-right safe corner")
		assert(c[1] >= 1908 - 0.1 * 353 * 2.625, "cluster left edge within 0.1H of the spec region")
	end,

	["regions fit and never overlap at smaller viewports"] = function()
		local sizes: { { any } } =
			{ { 1280, 720, 36, false }, { 1920, 1080, 0, false }, { 780, 390, 36, true }, { 640, 339, 36, true } }
		for _, size in sizes do
			check(size[1], size[2], size[3], size[4])
		end
	end,

	["cluster contents per context hold 5-7 tokens and keep slots"] = function()
		local explore = Shell.tokens(flags({}))
		assert(#explore == 5 and explore[1].slot == "P" and explore[1].id == "interact", "explore")
		local riding = Shell.tokens(flags({ mount = true }))
		assert(#riding == 6, "mount adds a token")
		local combat = Shell.tokens(flags({ combat = true, attack = true, shoot = true }))
		assert(#combat == 7 and combat[1].id == "attack" and combat[7].id == "shoot", "combat with ranged")
		local ranged = Shell.tokens(flags({ combat = true, shoot = true }))
		assert(ranged[1].id == "shoot" and #ranged == 6, "ranged only")
		for _, set in { explore, riding, combat } do
			local dodge = nil
			for _, token in set do
				if token.id == "dodge" then
					dodge = token.slot
				end
			end
			assert(dodge == "I1", "dodge keeps its slot across contexts")
		end
		assert(#Shell.tokens(flags({ building = true })) == 0, "placement bar owns build mode")
	end,

	["palette and type scale follow the spec"] = function()
		local p = Shell.PALETTE
		assert(p.tealDeep.r == 0x1F and p.tealDeep.g == 0x4E and p.tealDeep.b == 0x4C, "tealDeep")
		assert(p.bone.r == 0xED and p.coral.r == 0xD9 and p.ink.b == 0x24, "bone, coral, ink")
		assert(Shell.textSize("label", 353) == 12 and Shell.textSize("label", 1022) == 18, "label pt and PC cap")
		assert(Shell.tokenSize("L", 1022, false) == 64 and Shell.tokenSize("S", 353, true) == 44, "token sizes")
	end,

	["no shipped asset key names a hex shape"] = function()
		local fs = require("@lune/fs")
		local manifest = fs.readFile("games/robango-island/assets/manifest.yml")
		assert(not string.find(string.lower(manifest), "hex", 1, true), "no hex asset keys")
	end,

	["label targets: within 40 studs, nearest first, stable ties, capped"] = function()
		local list = {}
		for i = 1, 40 do
			table.insert(list, { id = string.format("n%02d", i), kind = "node", x = i, y = 0, z = 0 })
		end
		table.insert(list, { id = "b", kind = "npc", x = 3, y = 0, z = 0 })
		table.insert(list, { id = "a", kind = "pet", x = -3, y = 0, z = 0 })
		local picked = Shell.labelTargets(list, 0, 0, 0)
		assert(#picked == Shell.LABEL_LIMIT, "capped")
		assert(picked[1].id == "n01" and picked[2].id == "n02", "nearest first")
		assert(picked[3].id == "a" and picked[4].id == "b" and picked[5].id == "n03", "ties by id")
		assert(#Shell.labelTargets(list, 0, 0, 0, 40, 100) == 42, "all within 40 studs when uncapped")
	end,

	["minimap point and XY coordinates"] = function()
		local x, y = Shell.mapPoint(0, 0, 200)
		assert(x == 100 and y == 100, "centre")
		x, y = Shell.mapPoint(80, -80, 200)
		assert(x == 200 and y == 0, "corner")
		assert(Shell.mapPoint(81, 0, 200) == nil, "outside")
		local cx, cz = Shell.coords(12.4, -7.6)
		assert(cx == 12 and cz == -8, "rounded")
		assert(Shell.topClear(58, 0) == 58 and Shell.topClear(58, 58) == 0, "topClear in gui space")
	end,
}
