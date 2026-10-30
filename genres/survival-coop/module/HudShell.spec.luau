--!strict
-- HudShell regions against ui-spec.md section 5 (Robango A4, G5): the spec's pixel rects at the
-- 2400x1080 phone (SM-N981N, scale 2.625, side inset 32, top bar 58 logical) and 1920x1080 PC
-- (top bar 58), all inside the safe area, below the top bar and never overlapping.
local Shell = require("./HudShell")
-- ImageLabel IsLoaded / GetPropertyChangedSignal for the picker specs (registered once per process).
local _imageLoad = require("../../../core/ui-kit/ImageLoad.fixture")

local REGIONS =
	{ "vitals", "chips", "tracker", "status", "minimap", "coords", "quest", "questToggle", "hotbar", "row", "cluster" }

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
	-- hud2 (iconfix capture hud-phone-800x360): the hotbar drew bare numbers 1-6 over the ground with
	-- no slot frames, and each slot's item name sat under the bar, stacking into the next line
	-- ("돌무더기" over another). Framed tray and slots, icon + count inside the slot, one tooltip.
	["hud2: hotbar slots are framed, hold icon and count inside, and show one tooltip above the tray"] = function()
		for _, view: { any } in { { 800, 360, 0, true } :: { any }, { 1280, 720, 36, false } } do
			local width, height, top, touch = view[1], view[2], view[3], view[4]
			local r = Shell.regions(width, height, top, touch)
			local at = string.format(" at %dx%d", width, height)
			local tray = Shell.hotbarTray(r.hotbar)
			assert(Shell.inside(tray, width, height, top), "tray inside" .. at)
			assert(
				tray.x < r.hotbar.x and tray.x + tray.width > r.hotbar.x + r.hotbar.width,
				"tray frames the slots" .. at
			)
			assert(not Shell.overlaps(tray, r.row) and not Shell.overlaps(tray, r.cluster), "tray clears buttons" .. at)
			for _, token in r.tokens do
				assert(not Shell.overlaps(tray, token), "tray clears every action token" .. at)
			end
			local inside = Shell.hotbarSlot(r.hotbar.height)
			local parts: { { any } } = { { "icon", inside.icon }, { "key", inside.key }, { "count", inside.count } }
			for _, part in parts do
				local name: string, rect: any = part[1], part[2]
				assert(
					rect.x >= 0
						and rect.y >= 0
						and rect.x + rect.width <= r.hotbar.height
						and rect.y + rect.height <= r.hotbar.height,
					name .. " inside the slot" .. at
				)
			end
			assert(inside.icon.width >= r.hotbar.height * 0.6, "icon fills the slot" .. at)
			-- One tooltip for the selected slot: above the tray, within its width, under the screen's
			-- middle band where the character stands (it never covers the player).
			for index = 1, r.hotbarSlots do
				local tip = Shell.hotbarTip(r.hotbar, index, 13)
				assert(tip.y + tip.height <= tray.y, "tooltip above the tray" .. at)
				assert(tip.x >= tray.x and tip.x + tip.width <= tray.x + tray.width, "tooltip within the tray" .. at)
				assert(tip.y >= top + 0.62 * (height - top), "tooltip clear of the character" .. at)
				assert(
					not Shell.overlaps(tip, r.row) and not Shell.overlaps(tip, r.cluster),
					"tooltip clears buttons" .. at
				)
			end
		end
		-- The framed hotbar (tray + selected-slot tooltip) blocks world labels (iconfix frame: the
		-- stone-pile label "돌무더기 / 맨손" read through the slots).
		local phone = Shell.regions(800, 360, 0, true)
		local frame = phone.hotbarFrame
		local tray = Shell.hotbarTray(phone.hotbar)
		assert(frame.y < tray.y and frame.y + frame.height == tray.y + tray.height, "frame covers tray and tip")
		assert(
			Shell.labelBlocked(Shell.labelRect(580, tray.y + tray.height - 4, "돌무더기", "맨손"), phone),
			"slots"
		)
		assert(Shell.labelBlocked(Shell.labelRect(tray.x + 30, frame.y + 6, "도도"), phone), "tooltip band")
		local empty, filled, selected =
			Shell.hotbarLook("empty"), Shell.hotbarLook("filled"), Shell.hotbarLook("selected")
		assert(empty.fill > filled.fill and filled.fill >= selected.fill, "empty slot dimmed, filled solid")
		assert(empty.fill < 1 and empty.rimAlpha < 1, "an empty slot still shows its frame")
		assert(
			selected.rim == "ochre" and filled.rim ~= "ochre" and selected.rimWidth > filled.rimWidth,
			"selected slot highlighted"
		)
		-- The HUD wires it: a tray, the per-slot count, one HotbarTip.
		local source = require("@lune/fs").readFile("genres/survival-coop/module/SurvivalHUD.luau")
		for _, needle in
			{
				'"HotbarTray"',
				'"HotbarTip"',
				'"Count"',
				"HudShell.hotbarSlot(",
				"HudShell.hotbarLook(",
				"HudShell.hotbarTip(",
			}
		do
			assert(string.find(source, needle, 1, true), "SurvivalHUD hotbar uses " .. needle)
		end
	end,
	-- D2c top fix: the hotbar (and the bottom-left row) hid only under the HUD's own sheet; it drew
	-- over the down card, under the carcass picker's Leave pill and over the survivor picker.
	["hud2: the hotbar and bottom row hide under any full sheet or picker and return on close"] = function()
		local attributes: { [string]: any } = {}
		local function read(name: string): any
			return attributes[name]
		end
		local function gui(enabled: boolean): any
			local close = { ClassName = "TextButton", Name = "Close" }
			local header = {
				ClassName = "Frame",
				Name = "Header",
				FindFirstChild = function(_, n)
					return if n == "Close" then close else nil
				end,
			}
			local frame = {
				ClassName = "Frame",
				Name = "SurvivorPicker",
				Visible = true,
				FindFirstChild = function(_, n)
					return if n == "Header" then header else nil
				end,
				GetChildren = function()
					return { header }
				end,
			}
			return {
				ClassName = "ScreenGui",
				Name = "ForgeSurvivorPicker",
				Enabled = enabled,
				GetChildren = function()
					return { frame }
				end,
			}
		end
		local children: { any } = {}
		local playerGui = {
			GetChildren = function()
				return children
			end,
		}
		assert(Shell.bottomHidden(playerGui, read) == false, "shown in play")
		for _, flag in
			{
				"ForgeSurvivalSheetOpen",
				"ForgeExtensionSheetOpen",
				"ForgeDownPanelOpen",
				"ForgeCarcassPickerOpen",
			}
		do
			attributes[flag] = true
			assert(Shell.bottomHidden(playerGui, read), "hidden under " .. flag)
			attributes[flag] = nil
			assert(not Shell.bottomHidden(playerGui, read), "back after " .. flag)
		end
		children[1] = gui(true)
		assert(Shell.bottomHidden(playerGui, read), "hidden under the survivor picker")
		children[1] = gui(false)
		assert(not Shell.bottomHidden(playerGui, read), "back once the picker closes")
		-- SurvivalHUD drives both the hotbar and the bottom-left row from it.
		local source = require("@lune/fs").readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(source, "HudShell.bottomHidden(", 1, true), "HUD asks bottomHidden")
		assert(string.find(source, "hotbarStep(bottomHidden)", 1, true), "hotbar follows it")
		assert(string.find(source, "local rowVisible = not bottomHidden", 1, true), "bottom row follows it")
	end,
	-- p134 v57: the hunger banner (status region, 0.16H, screen middle) covered half of the companion
	-- name tag. Banners now sit in a top lane between the vitals and the minimap/quest card and move
	-- to the next lane when a shown name tag (or the combat target bar) is in the way.
	["hud2: contextual banners never overlap world name tags of the player or companion"] = function()
		local views: { { any } } = { { 800, 360, 0, true }, { 1280, 720, 36, false }, { 1280, 720, 0, false } }
		for _, view in views do
			local width, height, top, touch = view[1], view[2], view[3], view[4]
			local r = Shell.regions(width, height, top, touch)
			local h = height - top
			local at = string.format(" at %dx%d", width, height)
			for _, lane in { r.banner, r.bannerAlt } do
				assert(lane.width >= 200 and lane.height >= 30, "lane holds two lines" .. at)
				assert(Shell.inside(lane, width, height, top), "lane inside" .. at)
				for _, id in REGIONS do
					if id ~= "status" then
						assert(not Shell.overlaps(lane, r[id]), "banner lane clears " .. id .. at)
					end
				end
			end
			-- The v57 frame: the companion tag sat at about 0.15-0.22H, in the old status region; the
			-- player's own tag hangs under the character mid-screen.
			local companion = { x = width / 2 - 80, y = top + 0.15 * h, width = 160, height = 26 }
			local own = { x = width / 2 - 110, y = top + 0.5 * h, width = 220, height = 40 }
			assert(Shell.overlaps(r.status, companion), "fixture reproduces the v57 overlap" .. at)
			local chosen = Shell.bannerRect(r, { companion, own })
			assert(
				not Shell.overlaps(chosen, companion) and not Shell.overlaps(chosen, own),
				"banner clears the tags" .. at
			)
			assert(chosen.y + chosen.height <= top + 0.15 * h, "default lane is above the tag band" .. at)
			-- A tag (or the target bar) up in the top lane: the banner takes the left lane instead.
			local high = { x = r.banner.x + 20, y = r.banner.y, width = 160, height = 26 }
			local moved = Shell.bannerRect(r, { high, own })
			assert(
				not Shell.overlaps(moved, high) and not Shell.overlaps(moved, own),
				"banner moves off a high tag" .. at
			)
			assert(
				not Shell.overlaps(Shell.feedback(width, height, top, touch).banner, companion),
				"skill banner clears the companion tag" .. at
			)
		end
		-- Name tags are tagged for the HUD to steer around: player tags, pet labels, the companion plate.
		local fs = require("@lune/fs")
		local shell = fs.readFile("genres/survival-coop/module/HudShell.luau")
		assert(select(2, string.gsub(shell, "AddTag%(M%.NAME_TAG%)", "")) >= 2, "player tag and pet label tagged")
		local opening = fs.readFile("games/robango-island/src/shared/OpeningClient.luau")
		assert(string.find(opening, 'AddTag("' .. Shell.NAME_TAG .. '")', 1, true), "companion plate tagged")
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, "HudShell.bannerRect(shellRegions", 1, true), "HUD places the banner around tags")
	end,
	-- HUD polish (Durango R05/R08): the owner's two target screens, phone 800x360 (CoreUISafeInsets,
	-- no top clear) and PC 1280x720 (36 px top bar).
	["HUD polish: compact regions at 800x360 phone and 1280x720 PC"] = function()
		for _, view: { any } in { { 800, 360, 0, true } :: { any }, { 1280, 720, 36, false } } do
			local width, height, top, touch = view[1], view[2], view[3], view[4]
			local r = check(width, height, top, touch)
			local at = string.format(" at %dx%d", width, height)
			-- Slim vitals: at most a quarter of the width and 30% of the safe height (v54: half the corner).
			assert(r.vitals.width <= width * 0.27 and r.vitals.height <= r.safeHeight * 0.3, "compact vitals" .. at)
			local rows = Shell.vitalsRows(r.vitals)
			assert(rows.badge.x >= 0 and rows.badge.y >= 0, "badge inside" .. at)
			for index, row in rows.rows do
				assert(row.track.width >= 80, "bar track stays a bar" .. at)
				assert(row.icon.x >= rows.badge.x + rows.badge.width, "icon right of the badge" .. at)
				assert(row.track.x >= row.icon.x + row.icon.width, "bar right of the icon" .. at)
				assert(row.value.x >= row.track.x + row.track.width, "number right of the bar" .. at)
				assert(row.value.x + row.value.width <= r.vitals.width, "number inside the panel" .. at)
				assert(row.value.y + row.value.height <= r.vitals.height, "row inside the panel" .. at)
				if index > 1 then
					local above = rows.rows[index - 1].track
					assert(row.track.y > above.y + above.height, "rows apart" .. at)
				end
			end
			assert(rows.text >= 11, "vitals number readable" .. at)
			-- Every touch target is at least 44 px; the primary token is the big one.
			for slot, token in r.tokens do
				assert(not touch or math.min(token.width, token.height) >= Shell.MIN_TOUCH, slot .. " touch" .. at)
				if slot ~= "P" then
					assert(r.tokens.P.width > token.width, "primary bigger than " .. slot .. at)
				end
			end
			for _, rect in { r.questToggle, table.unpack(r.rowSlots) } do
				assert(rect.width >= Shell.MIN_TOUCH and rect.height >= Shell.MIN_TOUCH, "toggle / row touch" .. at)
			end
			-- Hotbar slots: bottom centre, touch size, between the bottom-left row and the cluster.
			local bar = r.hotbar
			assert(bar.height >= Shell.MIN_TOUCH, "hotbar slot touch size" .. at)
			assert(math.abs(bar.x + bar.width / 2 - width / 2) <= 1, "hotbar centred" .. at)
			assert(
				bar.x > r.row.x + r.row.width and bar.x + bar.width < r.cluster.x,
				"hotbar between row and arc" .. at
			)
			assert(r.hotbarSlots == Shell.HOTBAR_SLOTS, "six slots" .. at)
			-- The quest toggle sits left of the card on the card's top line.
			assert(r.questToggle.y == r.quest.y and r.questToggle.x + r.questToggle.width < r.quest.x, "toggle" .. at)
		end
	end,

	["HUD polish: every token has a painted icon and the disabled look reads as unavailable"] = function()
		local fs = require("@lune/fs")
		local manifest = fs.readFile("games/robango-island/assets/manifest.yml")
		local ids = { "rest", "gather", "menu", "emote", "chat", "quest", "currency", "level", "dismount", "pet" }
		for _, set in { flags({ combat = true, attack = true, shoot = true, capture = true }), flags({ mount = true }) } do
			for _, token in Shell.tokens(set) do
				table.insert(ids, token.id)
			end
		end
		for _, id in ids do
			local icon = assert(Shell.TOKEN_ICONS[id], "icon for " .. id)
			local key = "key: ui-icon-" .. string.gsub(icon, "[.]", "-") .. "\n"
			assert(string.find(manifest, key, 1, true), "manifest row for " .. icon)
			assert(fs.isFile("games/robango-island/assets/icons/ui.icon." .. icon .. ".png"), "png for " .. icon)
		end
		-- The interact token shows what it will do; the stance token the current stance.
		assert(Shell.tokenIcon("interact", { rest = true }) == "hud.rest", "rest glyph")
		assert(Shell.tokenIcon("interact", { gather = true }) == "hud.gather", "gather glyph")
		assert(Shell.tokenIcon("interact") == "hud.interact", "default glyph")
		assert(Shell.tokenIcon("stance", { stance = "defense" }) == "stance.defense", "current stance")
		assert(Shell.tokenIcon("stance", { stance = "none" }) == "stance.attack", "no stance")
		-- Disabled: the same disc with the glyph dimmed and a slate rim, never a near-invisible blob.
		local off, on, primary = Shell.tokenLook("disabled"), Shell.tokenLook("normal"), Shell.tokenLook("primary")
		assert(off.fill < 0.7 and off.glyph > 0.3 and off.glyph < 0.8, "disabled stays visible but dim")
		assert(off.rim == "slateLock" and on.rim == "drift" and primary.rim == "tealPale", "rims")
		assert(primary.fill < on.fill and on.fill < off.fill, "primary most solid")
	end,

	["regions match ui-spec section 5 at 1920x1080 PC"] = function()
		local r = check(PC[1], PC[2], PC[3], PC[4])
		-- HUD polish: the vitals panel is the compact Durango strip (spec corner, capped width) instead
		-- of the spec's 450 px slab.
		local v = physical(r.vitals, PC)
		near("vitals corner", { v[1], v[2], 0, 0 }, { 20, 78, 0, 0 }, 2)
		assert(r.vitals.width <= Shell.VITALS_MAX_WIDTH and r.vitals.height <= 3 * Shell.VITALS_ROW[2] + 8, "compact")
		assert(r.vitals.height >= Shell.VITALS_MIN_HEIGHT, "vitals holds its three bar rows")
		assert(r.chips.y >= r.vitals.y + r.vitals.height and r.tracker.y >= r.chips.y + r.chips.height, "stacked")
		near("minimap", physical(r.minimap, PC), { 1664, 78, 225, 225 }, 2)
		near("coords", physical(r.coords, PC), { 1685, 308, 184, 41 }, 2)
		near("quest", physical(r.quest, PC), { 1389 + Shell.MIN_TOUCH + 4, 365, 501 - Shell.MIN_TOUCH - 4, 123 }, 2)
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
		-- The spec's 0.12H vitals rect (111 px tall here) cannot hold the three 24 px bar rows, which spilled
		-- over the coin chip on the phone (staging v25): the panel keeps the spec's top-left corner and
		-- width, grows to VITALS_MIN_HEIGHT, and the chips and tracker stack under it.
		local v = physical(r.vitals, PHONE)
		near("vitals corner", { v[1], v[2], 0, 0 }, { 103, 171, 0, 0 }, 4)
		assert(r.vitals.width >= Shell.VITALS_MIN_WIDTH, "vitals wide enough for a bar track")
		assert(r.vitals.height >= Shell.VITALS_MIN_HEIGHT, "vitals holds its three bar rows")
		assert(r.chips.y >= r.vitals.y + r.vitals.height, "chips under vitals")
		near("minimap", physical(r.minimap, PHONE), { 2084, 171, 204, 204 }, 4)
		near("coords", physical(r.coords, PHONE), { 2103, 380, 167, 37 }, 4)
		-- Touch: the quest card moves left of the minimap (same top and height), clear of the cluster.
		assert(r.quest.y == r.minimap.y and r.quest.x + r.quest.width < r.minimap.x, "quest beside the minimap")
		assert(r.quest.y + r.quest.height < r.cluster.y, "quest above the cluster")
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
		local sizes: { { any } } = {
			{ 1280, 720, 36, false },
			{ 1920, 1080, 0, false },
			{ 780, 390, 36, true },
			{ 640, 339, 36, true },
			-- SM-N981N in a CoreUISafeInsets gui (topClear 0 since staging v25's double-inset fix).
			{ 800, 360, 0, true },
			{ 850, 411, 0, true },
		}
		for _, size in sizes do
			local r = check(size[1], size[2], size[3], size[4])
			if size[4] then
				-- Touch tokens keep EDGE off the screen's bottom and right edges (rounded corners).
				local c = r.cluster
				local margin = math.floor(Shell.EDGE * r.safeHeight)
				assert(c.x + c.width <= size[1] - margin and c.y + c.height <= size[2] - margin, "cluster edge margin")
				assert(Shell.tokenText("label", r.safeHeight, true) >= 13, "touch token text")
			end
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
		-- Creatures (not capped per kind like gather nodes) fill the board pool up to LABEL_LIMIT.
		for i = 1, 40 do
			table.insert(list, { id = string.format("n%02d", i), kind = "wildlife", x = i, y = 0, z = 0 })
		end
		table.insert(list, { id = "b", kind = "npc", x = 3, y = 0, z = 0 })
		table.insert(list, { id = "a", kind = "pet", x = -3, y = 0, z = 0 })
		local picked = Shell.labelTargets(list, 0, 0, 0)
		assert(#picked == Shell.LABEL_LIMIT, "capped")
		assert(picked[1].id == "n01" and picked[2].id == "n02", "nearest first")
		assert(picked[3].id == "a" and picked[4].id == "b" and picked[5].id == "n03", "ties by id")
		assert(#Shell.labelTargets(list, 0, 0, 0, 40, 100) == 42, "all within 40 studs when uncapped")
	end,
	["label targets cap gather nodes apart so a node field leaves boards for NPCs and creatures"] = function()
		local list = {}
		for i = 1, 20 do
			table.insert(list, { id = string.format("n%02d", i), kind = "node", x = i, y = 0, z = 0 })
		end
		table.insert(list, { id = "w", kind = "wildlife", x = 30, y = 0, z = 0 })
		local picked = Shell.labelTargets(list, 0, 0, 0)
		local nodes, wildlife = 0, false
		for _, candidate in picked do
			nodes += if candidate.kind == "node" then 1 else 0
			wildlife = wildlife or candidate.kind == "wildlife"
		end
		assert(nodes == Shell.NODE_LABEL_LIMIT, "node labels capped at " .. Shell.NODE_LABEL_LIMIT .. ", got " .. nodes)
		assert(picked[1].id == "n01" and wildlife, "nearest nodes first, the creature still labelled")
	end,

	-- p134 v54: walking to the dock "the camera yaw changes made it hard to aim". The camera yaw
	-- never changed (fixed 45 degrees); the minimap was north-up while the view looks along 45
	-- degrees, so map and screen disagreed by 135 degrees. The map now turns with the camera.
	["the minimap turns with the camera so map up is screen up"] = function()
		local h = math.sqrt(0.5)
		local function close(x: number?, y: number?, ex: number, ey: number, what: string)
			assert(
				x and y and math.abs(x - ex) < 1e-6 and math.abs(y - ey) < 1e-6,
				what .. ": " .. tostring(x) .. "," .. tostring(y)
			)
		end
		-- QuarterView yaw 45 looks along (-h, -h): ahead on screen is up on the map.
		local x, y = Shell.mapPoint(-10 * h, -10 * h, 200, 160, -h, -h)
		close(x, y, 100, 100 - 10 / 80 * 100, "ahead is up")
		-- The camera's right (h, -h) is map right.
		x, y = Shell.mapPoint(10 * h, -10 * h, 200, 160, -h, -h)
		close(x, y, 100 + 10 / 80 * 100, 100, "right is right")
		-- No camera: north-up as before.
		x, y = Shell.mapPoint(80, -80, 200)
		close(x, y, 200, 0, "north-up fallback")
		local source = require("@lune/fs").readFile("genres/survival-coop/module/HudShell.luau")
		for _, needle in
			{
				"local view = if camera then camera.CFrame.LookVector else Vector3.new(0, 0, -1)",
				"M.mapPoint(at.X - origin.X, at.Z - origin.Z, side, nil, view.X, view.Z)",
				"M.mapPoint(look.X * 10, look.Z * 10, 2, 40, view.X, view.Z)",
			}
		do
			assert(string.find(source, needle, 1, true), needle .. " wired")
		end
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
	["a foreign full sheet hides the HUD; HUD guis and hidden sheets do not"] = function()
		local function node(class: string, name: string, props: any?, children: { any }?): any
			local item: any = if props then props else {}
			item.ClassName, item.Name = class, name
			local list: { any } = if children then children else {}
			function item.GetChildren()
				return list
			end
			function item.FindFirstChild(_self, wanted: string)
				for _, child in list do
					if child.Name == wanted then
						return child
					end
				end
				return nil
			end
			return item
		end
		local function picker(enabled: boolean, visible: boolean): any
			local header = node("Frame", "Header", nil, { node("TextButton", "Close") })
			local frame = node("Frame", "SurvivorPicker", { Visible = visible }, { header })
			return node("ScreenGui", "ForgeSurvivorPicker", { Enabled = enabled }, { frame })
		end
		local function hudSheet(): any
			local header = node("Frame", "Header", nil, { node("TextButton", "Close") })
			local frame = node("Frame", "SurvivalSheet", { Visible = true }, { header })
			local root = node("Frame", "Root", { Visible = true }, { frame })
			return node("ScreenGui", "ForgeSurvivalHUD", { Enabled = true }, { root })
		end
		assert(Shell.sheetOpen(node("PlayerGui", "PlayerGui", nil, { picker(true, true) })), "open picker")
		assert(not Shell.sheetOpen(node("PlayerGui", "PlayerGui", nil, { picker(false, true) })), "disabled gui")
		assert(not Shell.sheetOpen(node("PlayerGui", "PlayerGui", nil, { picker(true, false) })), "hidden sheet")
		assert(not Shell.sheetOpen(node("PlayerGui", "PlayerGui", nil, { hudSheet() })), "own HUD sheet")
		assert(not Shell.sheetOpen(nil), "no PlayerGui")
	end,
	["gather fan keeps 2-6 pebbles apart, inside the safe area, on landscape phones and PC"] = function()
		-- { width, height, topClear, touch }: 800x360 and 850x411 landscape phones (logical), PC.
		local views: { { any } } = { { 800, 360, 36, true }, { 850, 411, 58, true }, { 1920, 1080, 58, false } }
		for _, view in views do
			local width, height, top, touch = view[1], view[2], view[3], view[4]
			for count = 2, Shell.FAN.maximum do
				-- Node in the middle, at each corner and at the bottom edge: the fan shifts inside.
				for _, at in
					{ { width / 2, height / 2 }, { 10, top + 10 }, { width - 10, height - 10 }, { width / 2, height } }
				do
					local fan = Shell.fan(width, height, top, touch, at[1], at[2], count)
					assert(#fan.tokens == count and #fan.captions == count, "one pebble and caption per output")
					local where = string.format("%dx%d n=%d at %d,%d", width, height, count, at[1], at[2])
					assert(Shell.inside(fan.name, width, height, top), "name pill inside " .. where)
					local middle = fan.tokens[math.ceil(count / 2)]
					assert(middle.y + middle.height < fan.name.y, "fan opens upward over the target " .. where)
					for index, token in fan.tokens do
						assert(Shell.inside(token, width, height, top), "token inside " .. where)
						assert(Shell.inside(fan.captions[index], width, height, top), "caption inside " .. where)
						assert(token.width >= (if touch then Shell.MIN_TOUCH else 0), "touch-size token " .. where)
						assert(not Shell.overlaps(token, fan.name), "pebble clears the name pill " .. where)
						assert(not Shell.overlaps(fan.captions[index], fan.name), "caption clears the pill " .. where)
						for other = index + 1, count do
							assert(not Shell.circlesOverlap(token, fan.tokens[other]), "pebbles apart " .. where)
						end
					end
				end
			end
		end
	end,
	["item toasts and the skill banner sit in their spec regions without overlapping"] = function()
		for _, view in { { 800, 360, 36 }, { 850, 411, 58 }, { 1920, 1080, 58 } } do
			local feedback = Shell.feedback(view[1], view[2], view[3])
			assert(#feedback.toasts == 3, "stack of three")
			assert(Shell.inside(feedback.banner, view[1], view[2], view[3]), "banner inside")
			for index, toast in feedback.toasts do
				assert(Shell.inside(toast, view[1], view[2], view[3]), "toast inside")
				assert(not Shell.overlaps(toast, feedback.banner), "toast clears the banner")
				if index > 1 then
					assert(not Shell.overlaps(toast, feedback.toasts[index - 1]), "toasts stack")
				end
			end
		end
	end,
	["a skill level-up is a mastery level that rose, never the first snapshot"] = function()
		assert(#Shell.levelUps(nil, { gathering = { level = 3 } }) == 0, "baseline")
		local ups = Shell.levelUps(
			{ gathering = { level = 2 }, melee = { level = 1 }, farming = { level = 4 } },
			{ gathering = { level = 3 }, melee = { level = 1 }, farming = { level = 6 } }
		)
		assert(#ups == 2 and ups[1].id == "farming" and ups[1].level == 6, "sorted rises")
		assert(ups[2].id == "gathering" and ups[2].level == 3, "gathering rose")
	end,
	["C4 capture token on a downed target and the riding cluster"] = function()
		local explore = Shell.tokens(flags({ capture = true }))
		assert(explore[#explore].slot == "X" and explore[#explore].id == "capture", "capture token in the X slot")
		local combat = Shell.tokens(flags({ combat = true, attack = true, shoot = true, capture = true }))
		assert(combat[#combat].id == "capture" and #combat == 7, "capture replaces the ranged extra in combat")
		local riding = Shell.tokens(flags({ riding = true, mount = true }))
		assert(Shell.context(flags({ riding = true })) == "mount", "riding context")
		assert(riding[1].slot == "P" and riding[1].id == "dismount", "dismount is primary")
		local ids = {}
		for _, token in riding do
			ids[token.id] = token.slot
		end
		assert(ids.pet == "I2" and ids.dodge == nil and ids.build == nil, "pet ring, no dodge or build while riding")
		assert(Shell.context(flags({ riding = true, building = true })) == "build", "placement still wins")
	end,
	["world labels survive a respawn and rebuild a board whose label was destroyed"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local I = roblox.Instance
		local playerGui = I.new("PlayerGui")
		local gui = I.new("ScreenGui")
		gui.AbsoluteSize, gui.ResetOnSpawn, gui.Parent = roblox.Vector2.new(850, 411), false, playerGui
		local root = {
			Position = roblox.Vector3.new(0, 0, 0),
			CFrame = roblox.CFrame.new(),
			IsA = function(_, class)
				return class == "BasePart"
			end,
		}
		local character = {
			FindFirstChild = function(_, name)
				return if name == "HumanoidRootPart" then root else nil
			end,
		}
		local player = {
			Character = character,
			WaitForChild = function()
				return playerGui
			end,
		}
		local node = I.new("Part")
		node.Position = roblox.Vector3.new(4, 0, 0)
		node:SetAttribute("ForgeNodeKind", "fiber")
		-- A dressed node: the shown mesh stands 6 studs tall over the invisible handle.
		local mesh = I.new("Part")
		mesh.Size, mesh.Position, mesh.Parent = roblox.Vector3.new(4, 6, 4), roblox.Vector3.new(4, 2, 0), node
		local beats: { (number) -> () } = {}
		local function signal(list: { any }?)
			return {
				Connect = function(_, fn)
					if list then
						table.insert(list, fn)
					end
					return { Disconnect = function() end }
				end,
			}
		end
		local services: { [string]: any } = {
			Players = {
				LocalPlayer = player,
				PlayerRemoving = signal(),
				GetPlayers = function()
					return {}
				end,
			},
			CollectionService = {
				GetTagged = function(_, tag)
					return if tag == "ForgeSurvivalNode" then { node } else {}
				end,
			},
			Workspace = {
				GetDescendants = function()
					return {}
				end,
				FindFirstChild = function()
					return nil
				end,
			},
			RunService = { RenderStepped = signal(), Heartbeat = signal(beats) },
			UserInputService = { TouchEnabled = true },
			GuiService = {},
		}
		local environment: any = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
		}
		for key, value in roblox do
			environment[key] = value
		end
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = environment,
		})()
		shell.startOverlays({
			gui = gui,
			hidden = function()
				return false
			end,
			name = function(_, key)
				return key
			end,
			coordsText = function(x: number, z: number)
				return x .. "," .. z
			end,
			tribe = function()
				return ""
			end,
			hint = function(kind, part)
				return if kind == "node" and part == node then "Lv 1 - By hand" else nil
			end,
		})
		local function beat(): any
			beats[1](1)
			local labels = playerGui:FindFirstChild("ForgeWorldLabels")
			assert(labels and labels:GetAttribute("ForgeLabelCount") == 1, "one node labelled")
			local board = labels:FindFirstChild("WorldLabel")
			assert(board and board.Adornee == node and board.Text.Text == "fiber", "label shows the node")
			-- L10b: an AlwaysOnTop board never drew on the Studio client (same board drew depth-tested),
			-- so the node labels stayed invisible; it must ride above the node's mesh to pass the depth test.
			assert(board.AlwaysOnTop == false, "world label is depth-tested, not AlwaysOnTop")
			assert(board.Size.Y.Offset > 0 and board.MaxDistance >= Shell.LABEL_RADIUS, "sized and in range")
			assert(
				board.StudsOffsetWorldSpace.Y >= 5 + Shell.LABEL_BOARD.clear - 1e-3,
				"lifted over the 6-stud mesh: " .. tostring(board.StudsOffsetWorldSpace)
			)
			local hint = board:FindFirstChild("Hint")
			assert(hint and hint.Visible and hint.Text == "Lv 1 - By hand", "node tool hint line")
			return labels
		end
		beat()
		-- Respawn as the engine does it: every PlayerGui child except a non-resetting LayerCollector
		-- is destroyed (folders included, whatever their descendants say).
		for _, child in playerGui:GetChildren() do
			if not (child:IsA("LayerCollector") and child.ResetOnSpawn == false) then
				child:Destroy()
			end
		end
		local labels = beat()
		-- A board whose label is gone (any other teardown) is rebuilt instead of indexing nil.
		labels:FindFirstChild("WorldLabel").Text:Destroy()
		beat()
	end,
	-- p134 v43: with the fan open, the big gather button (prompt / touch / routed tap) re-opened the
	-- same fan and nothing was sent; only an output pebble gathered. A second open of the open node
	-- now gathers its default (first) output.
	["opening the open node again gathers its first output"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local gui = roblox.Instance.new("ScreenGui")
		local node = roblox.Instance.new("Part")
		local function signal()
			return {
				Connect = function()
					return { Disconnect = function() end }
				end,
			}
		end
		-- Registration is global to the Lune process; another spec in the same worker may own it already.
		pcall(roblox.implementProperty, "TextButton", "Activated", function()
			return signal()
		end)
		local services: { [string]: any } = {
			RunService = { RenderStepped = signal() },
			GuiService = {},
			UserInputService = { InputBegan = signal() },
			Players = { LocalPlayer = {} },
			Workspace = {},
		}
		local environment: any = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			task = {
				spawn = function(fn, ...)
					fn(...)
				end,
			},
		}
		for key, value in roblox do
			environment[key] = value
		end
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = environment,
		})()
		local sent: { string } = {}
		local picker = shell.startPicker({
			gui = gui,
			touch = function()
				return true
			end,
			hidden = function()
				return false
			end,
			offered = function()
				return { { item = "fiber", quantity = 3 }, { item = "leaves", quantity = 1 } }, 1
			end,
			nodeName = function()
				return "fern"
			end,
			itemName = function(item)
				return item
			end,
			icon = function()
				return nil
			end,
			gather = function(_, output)
				table.insert(sent, output)
				return { ok = true }
			end,
			text = function(key)
				return if key == "toast" then "+%d %s" else key
			end,
			reach = 10,
		})
		assert(picker.open(node) and #sent == 0, "the first open shows the fan only")
		assert(picker.node() == node, "the fan tracks its node")
		assert(picker.open(node), "the second open is handled")
		assert(#sent == 1 and sent[1] == "fiber", "the second open gathers the first output")
		picker.destroy()
	end,
	-- p134 v49: the first pick on a fan opened from the gather button answered "too far, move
	-- closer" (server reach 8 studs with a clear ray). A pick out of reach now walks up first and then
	-- gathers, like the combat approach; a NODE_UNREACHABLE answer walks closer and retries once.
	["a gather pick out of reach walks into range and then gathers"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local V = roblox.Vector3
		local gui = roblox.Instance.new("ScreenGui")
		local node = roblox.Instance.new("Part")
		node.Position, node.Parent = V.new(9, 0, 0), roblox.Instance.new("Folder")
		local root = { Position = V.new(0, 0, 0) }
		local function signal()
			return {
				Connect = function()
					return { Disconnect = function() end }
				end,
			}
		end
		-- Registered once per process; another spec in the run may have done it already.
		pcall(roblox.implementProperty, "TextButton", "Activated", function()
			return signal()
		end)
		local services: { [string]: any } = {
			RunService = { RenderStepped = signal() },
			GuiService = {},
			UserInputService = { InputBegan = signal() },
			Players = {
				LocalPlayer = {
					Character = {
						FindFirstChild = function(_, name)
							return if name == "HumanoidRootPart" then root else nil
						end,
					},
				},
			},
			Workspace = {},
		}
		local environment: any = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
			task = {
				spawn = function(fn, ...)
					fn(...)
				end,
			},
		}
		for key, value in roblox do
			environment[key] = value
		end
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = environment,
		})()
		local sent: { { item: string, at: number } } = {}
		local walks: { { within: number, arrive: () -> () } } = {}
		local answer: any = { ok = true }
		local picker = shell.startPicker({
			gui = gui,
			touch = function()
				return true
			end,
			hidden = function()
				return false
			end,
			offered = function()
				return { { item = "fiber", quantity = 3 }, { item = "branch", quantity = 1 } }, 1
			end,
			nodeName = function()
				return "fern"
			end,
			itemName = function(item)
				return item
			end,
			icon = function()
				return nil
			end,
			gather = function(_, output)
				table.insert(sent, { item = output, at = root.Position.X })
				return answer
			end,
			text = function(key)
				return if key == "toast" then "+%d %s" else key
			end,
			reach = 10,
			approach = function(part, within, arrive)
				assert(part == node, "walks to the picked node")
				table.insert(walks, { within = within, arrive = arrive })
			end,
		})
		-- The fan is open 9 studs away (inside the fan's 10, outside gather reach).
		assert(picker.open(node), "fan opens")
		assert(picker.open(node), "the gather button picks the default output")
		assert(#sent == 0 and #walks == 1, "no refused gather is sent: the character walks first")
		assert(walks[1].within <= shell.PICK_REACH, "walks inside gather reach")
		root.Position = V.new(7, 0, 0)
		walks[1].arrive()
		assert(#sent == 1 and sent[1].item == "fiber" and sent[1].at == 7, "gathers on arrival")
		-- In reach: gathers at once, no walk.
		picker.open(node)
		assert(#sent == 2 and #walks == 1, "in reach gathers at once")
		-- The server still says too far (height, a blocked ray): walk closer and retry once.
		answer = { ok = false, reason = "NODE_UNREACHABLE" }
		picker.open(node)
		assert(#sent == 3 and #walks == 2, "an unreachable answer walks closer")
		walks[2].arrive()
		assert(#sent == 4 and #walks == 2, "one retry after the walk, no loop")
		picker.destroy()
		-- The live wiring: the client hands the tap router's walk to the picker.
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "walkTo(part.Position, within, arrive)", 1, true), "picker approach")
		assert(string.find(client, "walkTo = tapInput.moveTo", 1, true), "bound to the tap router walk")
	end,
	["level badge shows the player's headshot in the ring, cached, with a painted fallback"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local environment: any = {
			task = {
				spawn = function(fn, ...)
					fn(...)
				end,
			},
		}
		for key, value in roblox do
			environment[key] = value
		end
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = environment,
		})()
		local calls: { any } = {}
		local players = {
			GetUserThumbnailAsync = function(_, userId, kind, size)
				table.insert(calls, { userId, kind, size })
				return "rbxthumb://type=AvatarHeadShot&id=" .. userId .. "&w=150&h=150", true
			end,
		}
		local badge = roblox.Instance.new("TextLabel")
		badge.Text = "7"
		local pip = shell.levelPortrait(badge, players, 42, "rbxassetid://1")
		local portrait = badge:FindFirstChild("Portrait")
		assert(portrait and portrait:IsA("ImageLabel"), "portrait image inside the badge")
		assert(portrait.Image == "rbxthumb://type=AvatarHeadShot&id=42&w=150&h=150", "headshot shown")
		assert(#calls == 1 and calls[1][2] == roblox.Enum.ThumbnailType.HeadShot, "one headshot request")
		assert(portrait:FindFirstChildOfClass("UICorner"), "round portrait")
		assert(pip and pip.Name == "LevelNumber" and pip.Parent == badge, "level number pip in the ring")
		assert(badge.Text == "", "the bare number disc is gone")
		-- Cached: a rebuilt badge for the same user draws the headshot at once, without a new request.
		local again = roblox.Instance.new("TextLabel")
		shell.levelPortrait(again, players, 42, "rbxassetid://1")
		assert(#calls == 1, "headshot cached per user")
		assert(again:FindFirstChild("Portrait").Image == portrait.Image, "cached headshot reused")
		-- A failed request keeps the painted fallback.
		local failing = {
			GetUserThumbnailAsync = function()
				error("HTTP 500")
			end,
		}
		local other = roblox.Instance.new("TextLabel")
		shell.levelPortrait(other, failing, 99, "rbxassetid://1")
		assert(other:FindFirstChild("Portrait").Image == "rbxassetid://1", "painted fallback kept")
		-- The live HUD builds its level badge through it and writes the level into the pip.
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, "HudShell.levelPortrait(badge, players, player.UserId", 1, true), "HUD wiring")
		assert(string.find(hud, "levelNumber.Text = ", 1, true), "level shown on the pip")
	end,
	["quest card toggle shows a different glyph expanded and collapsed"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = table.clone(roblox),
		})()
		local function icon(id: string): string?
			return "rbxassetid://" .. id
		end
		local button = roblox.Instance.new("TextButton")
		shell.questToggleLook(button, false, icon)
		local expanded = button:FindFirstChild("Glyph").Image
		assert(button:GetAttribute("ForgeQuestCollapsed") == false, "expanded state")
		shell.questToggleLook(button, true, icon)
		local collapsed = button:FindFirstChild("Glyph").Image
		assert(button:GetAttribute("ForgeQuestCollapsed") == true, "collapsed state")
		assert(expanded ~= collapsed, "glyph changes with the card state")
		assert(collapsed == "rbxassetid://" .. shell.TOKEN_ICONS.quest, "collapsed shows the quest glyph")
		assert(fs.isFile("games/robango-island/assets/icons/ui.icon." .. shell.TOKEN_ICONS.questHide .. ".png"))
		-- The dock's toggle restyles itself on every tap.
		local panels = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		local _, tap = string.find(panels, "questCollapsed = not questCollapsed", 1, true)
		assert(tap, "toggle flips the state")
		local after = string.sub(panels, tap, tap + 120)
		assert(string.find(after, "HudShell.questToggleLook(questToggle, questCollapsed", 1, true), "tap restyles")
	end,
	-- studio-after defects 1, 8/9, 10/11: at the default 50-60 stud camera no label drew (the board
	-- cut at 48 studs from the camera), creatures got a coral label, and boards drew over the minimap
	-- and hotbar. Labels are chosen from the character; a board never cuts on camera distance, every
	-- kind uses the one white style, and a board whose text lands on a HUD region is not shown.
	["world labels draw at the play camera, in one style, and never over HUD regions"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local CameraConfig = require("../../../games/robango-island/src/shared/CameraConfig")
		local I = roblox.Instance
		local playerGui = I.new("PlayerGui")
		local gui = I.new("ScreenGui")
		gui.AbsoluteSize, gui.ResetOnSpawn, gui.Parent = roblox.Vector2.new(800, 360), false, playerGui
		gui.AbsolutePosition = roblox.Vector2.zero
		local root = {
			Position = roblox.Vector3.new(0, 0, 0),
			CFrame = roblox.CFrame.new(),
			IsA = function(_, class)
				return class == "BasePart"
			end,
		}
		local player = {
			Character = {
				FindFirstChild = function(_, name)
					return if name == "HumanoidRootPart" then root else nil
				end,
			},
			WaitForChild = function()
				return playerGui
			end,
		}
		local function part(x: number, z: number): any
			local item = I.new("Part")
			item.Position = roblox.Vector3.new(x, 0, z)
			return item
		end
		local node = part(6, 0)
		node:SetAttribute("ForgeNodeKind", "fiber")
		local hidden = part(-6, 0)
		hidden:SetAttribute("ForgeNodeKind", "stone")
		local wild = I.new("Folder")
		wild.Name = "ForgeWildlife"
		local animal = I.new("Model")
		animal:SetAttribute("ForgeWildlifeKind", "dodo")
		local body = part(0, 8)
		body.Name, body.Parent, animal.PrimaryPart, animal.Parent = "HumanoidRootPart", animal, body, wild
		-- The play camera at its default distance; the fake projection puts the stone's label on the
		-- minimap (top right) and the others in open ground.
		local distance = math.max(CameraConfig.distance, 52)
		local camera = {
			CFrame = roblox.CFrame.new(0, distance * 0.8, distance * 0.6),
			WorldToViewportPoint = function(_, at: any)
				if at.X < 0 then
					return roblox.Vector3.new(750, 40, 10), true
				end
				return roblox.Vector3.new(400 + at.X * 5, 180 + at.Z * 3, 10), true
			end,
		}
		-- No top bar in this gui: screen and viewport points coincide.
		camera.WorldToScreenPoint = camera.WorldToViewportPoint
		local beats: { (number) -> () } = {}
		local function signal(list: { any }?)
			return {
				Connect = function(_, fn)
					if list then
						table.insert(list, fn)
					end
					return { Disconnect = function() end }
				end,
			}
		end
		local services: { [string]: any } = {
			Players = {
				LocalPlayer = player,
				PlayerRemoving = signal(),
				GetPlayers = function()
					return {}
				end,
			},
			CollectionService = {
				GetTagged = function(_, tag)
					return if tag == "ForgeSurvivalNode" then { node, hidden } else {}
				end,
			},
			Workspace = {
				CurrentCamera = camera,
				GetDescendants = function()
					return {}
				end,
				FindFirstChild = function(_, name)
					return if name == "ForgeWildlife" then wild else nil
				end,
			},
			RunService = { RenderStepped = signal(), Heartbeat = signal(beats) },
			UserInputService = { TouchEnabled = true },
			GuiService = {},
		}
		local environment: any = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
		}
		for key, value in roblox do
			environment[key] = value
		end
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = environment,
		})()
		shell.startOverlays({
			gui = gui,
			hidden = function()
				return false
			end,
			name = function(_, key)
				return key
			end,
			coordsText = function()
				return ""
			end,
			tribe = function()
				return ""
			end,
		})
		beats[1](1)
		local labels = playerGui:FindFirstChild("ForgeWorldLabels")
		local shown: { [string]: any } = {}
		for _, board in labels:GetChildren() do
			if board:IsA("BillboardGui") and board.Enabled then
				shown[board.Text.Text] = board
			end
		end
		assert(shown.fiber and shown.dodo, "the near node and the creature are labelled")
		assert(shown.stone == nil, "a label that would land on the minimap is not drawn")
		assert(labels:GetAttribute("ForgeLabelCount") == 2, "two boards shown")
		for key, board in shown do
			local cameraGap = (board.Adornee.Position - camera.CFrame.Position).Magnitude
			assert(board.MaxDistance >= cameraGap, key .. " board reaches the play camera, gap " .. cameraGap)
			assert(board.MaxDistance >= CameraConfig.maxDistance + Shell.LABEL_RADIUS, key .. " any zoom")
		end
		assert(shown.dodo.Text.TextColor3 == shown.fiber.Text.TextColor3, "creatures use the node label style")
		-- The region test itself, at both target screens.
		for _, view: { any } in { { 800, 360, 0, true } :: { any }, { 1280, 720, 36, false } } do
			local r = Shell.regions(view[1], view[2], view[3], view[4])
			local function at(region: any)
				return Shell.labelRect(
					region.x + region.width / 2,
					region.y + region.height / 2,
					"파라사우롤로푸스"
				)
			end
			for _, key in { "minimap", "quest", "questToggle", "hotbar", "hotbarFrame", "cluster", "vitals" } do
				assert(Shell.labelBlocked(at(r[key]), r), key .. " blocks labels at " .. view[1])
			end
			assert(not Shell.labelBlocked(Shell.labelRect(view[1] / 2, view[2] / 2, "도도"), r), "open ground")
		end
	end,
	-- p134 v60 lb4: node labels drew through the vitals panel, under the quest toggle and over hotbar
	-- slot 1. The skip tested WorldToViewportPoint against regions laid out in gui space, but the HUD
	-- gui (CoreUISafeInsets) starts under the top bar while its AbsolutePosition reads 0, and a viewport
	-- point is one bar height (58 px on the phone, Studio probe 331,136 vs screen 331,78) lower than the
	-- screen point. Every test ran a bar height below where the label draws. Now: the screen point.
	["v60: world labels skip the vitals, the quest toggle and the framed hotbar under a top bar"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local I, V3 = roblox.Instance, roblox.Vector3
		local INSET = 58
		local playerGui = I.new("PlayerGui")
		local gui = I.new("ScreenGui")
		gui.AbsoluteSize, gui.ResetOnSpawn, gui.Parent = roblox.Vector2.new(800, 302), false, playerGui
		gui.AbsolutePosition = roblox.Vector2.zero
		local r = Shell.regions(800, 302, 0, true)
		local function centre(region: any, dy: number?): { number }
			return { region.x + region.width / 2, region.y + region.height / 2 + (dy or 0) }
		end
		-- Gui points each node's label draws at, keyed by the node's x stud.
		local targets: { [number]: { number } } = {
			[1] = centre(r.vitals),
			[2] = centre(r.questToggle),
			[3] = { r.hotbar.x + r.hotbar.height / 2, r.hotbar.y + r.hotbar.height - 6 },
			[4] = { 400, 140 },
		}
		local root = {
			Position = V3.new(0, 0, 0),
			CFrame = roblox.CFrame.new(),
			IsA = function(_, class)
				return class == "BasePart"
			end,
		}
		local player = {
			Character = {
				FindFirstChild = function(_, name)
					return if name == "HumanoidRootPart" then root else nil
				end,
			},
			WaitForChild = function()
				return playerGui
			end,
		}
		local nodes = {}
		for index, key in { "vitals", "toggle", "slot1", "open" } do
			local node = I.new("Part")
			node.Position = V3.new(index, 0, 0)
			node:SetAttribute("ForgeNodeKind", key)
			table.insert(nodes, node)
		end
		local function project(at: any): any
			local t = targets[math.floor(at.X + 0.5)]
			return V3.new(t[1], t[2], 10)
		end
		local camera = {
			CFrame = roblox.CFrame.new(0, 40, 30),
			-- The screen point is where the label draws in this gui; the viewport point is the same
			-- spot measured from above the top bar (INSET px more).
			WorldToScreenPoint = function(_, at: any)
				return project(at), true
			end,
			WorldToViewportPoint = function(_, at: any)
				local p = project(at)
				return V3.new(p.X, p.Y + INSET, p.Z), true
			end,
		}
		local beats: { (number) -> () } = {}
		local function signal(list: { any }?)
			return {
				Connect = function(_, fn)
					if list then
						table.insert(list, fn)
					end
					return { Disconnect = function() end }
				end,
			}
		end
		local services: { [string]: any } = {
			Players = {
				LocalPlayer = player,
				PlayerRemoving = signal(),
				GetPlayers = function()
					return {}
				end,
			},
			CollectionService = {
				GetTagged = function(_, tag)
					return if tag == "ForgeSurvivalNode" then nodes else {}
				end,
			},
			Workspace = {
				CurrentCamera = camera,
				GetDescendants = function()
					return {}
				end,
				FindFirstChild = function()
					return nil
				end,
			},
			RunService = { RenderStepped = signal(), Heartbeat = signal(beats) },
			UserInputService = { TouchEnabled = true },
			GuiService = {},
		}
		local environment: any = {
			game = {
				GetService = function(_, name)
					return services[name]
				end,
			},
		}
		for key, value in roblox do
			environment[key] = value
		end
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = environment,
		})()
		shell.startOverlays({
			gui = gui,
			hidden = function()
				return false
			end,
			name = function(_, key)
				return key
			end,
			coordsText = function()
				return ""
			end,
			tribe = function()
				return ""
			end,
		})
		beats[1](1)
		local shown: { [string]: boolean } = {}
		for _, board in playerGui:FindFirstChild("ForgeWorldLabels"):GetChildren() do
			if board:IsA("BillboardGui") and board.Enabled then
				shown[board.Text.Text] = true
			end
		end
		assert(shown.open, "a label over open ground still draws")
		assert(not shown.vitals, "no label through the vitals panel")
		assert(not shown.toggle, "no label under the quest toggle")
		assert(not shown.slot1, "no label over hotbar slot 1")
		-- The skip set names the framed hotbar (tray + tooltip) and the quest toggle.
		assert(table.find(Shell.LABEL_BLOCKERS, "hotbarFrame"), "framed hotbar blocks labels")
		assert(
			table.find(Shell.LABEL_BLOCKERS, "questToggle") and table.find(Shell.LABEL_BLOCKERS, "vitals"),
			"blockers"
		)
	end,
	-- studio-after defect 2: the coin icon sat on the amount (the chip had no padding), so the pill
	-- read as empty. Icon first, then the amount, never overlapping.
	["coin chip lays out the icon, then the amount"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = table.clone(roblox),
		})()
		for _, chip in { 24, 28 } do
			local coins = roblox.Instance.new("TextLabel")
			coins.Text = "100"
			local icon = roblox.Instance.new("ImageLabel")
			icon.Name, icon.Parent = "CoinIcon", coins
			local left = shell.coinChip(coins, chip)
			local pad = coins:FindFirstChildOfClass("UIPadding")
			assert(pad and pad.PaddingLeft.Offset == left, "the amount starts after the left padding")
			-- Icon box in the chip's own space: the padded origin plus its offset.
			local iconLeft = left + icon.Position.X.Offset - icon.AnchorPoint.X * icon.Size.X.Offset
			local iconRight = iconLeft + icon.Size.X.Offset
			assert(iconLeft >= 0, "icon inside the chip")
			assert(iconRight <= left, "icon ends before the amount starts")
			assert(coins.TextXAlignment == roblox.Enum.TextXAlignment.Left, "amount follows the icon")
		end
		local source = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(
			string.find(source, "HudShell.coinChip(coins,", 1, true),
			"SurvivalHUD lays the chip out through coinChip"
		)
	end,
	-- studio-after defect 3: the primary caption ('채집하기', '모닥불에서 휴식 [R]') sat on the consume
	-- token and the slot under it. It now takes the first clear spot around the primary token.
	["the primary caption never covers another token or the hotbar"] = function()
		for _, view: { any } in { { 800, 360, 0, true } :: { any }, { 1280, 720, 36, false }, { 640, 339, 0, true } } do
			local width, height, top, touch = view[1], view[2], view[3], view[4]
			local r = Shell.regions(width, height, top, touch)
			for _, set in { { "P", "I1", "I3", "O1", "O2" }, { "P", "I1", "I2", "I3", "O1", "O2", "X" } } do
				local others = { r.hotbar }
				for _, slot in set do
					if slot ~= "P" then
						table.insert(others, r.tokens[slot])
					end
				end
				for _, caption in { "채집하기", "모닥불에서 휴식 [R]", "Rest at the campfire [R]" } do
					local size = Shell.tokenText("label", r.safeHeight, touch)
					local w = 0
					for _, code in utf8.codes(caption) do
						w += if code >= 0x1100 then size else size * 0.55
					end
					local spot = Shell.captionRect(r.tokens.P, w + 20, size + 10, others, width, height, top, r.cluster)
					assert(Shell.inside(spot, width, height, top), caption .. " inside at " .. width)
					for index, other in others do
						assert(
							not Shell.overlaps(spot, other),
							string.format("%s covers rect %d at %dx%d (%d tokens)", caption, index, width, height, #set)
						)
					end
				end
			end
		end
		local hud = require("@lune/fs").readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, "captionAvoid,", 1, true), "SurvivalHUD passes the rects to avoid")
	end,
	-- studio-after defect 4: the cold open's Skip (top right) covered the arrival sheet's close X.
	["a corner button never covers an open sheet's header"] = function()
		local EP = require("./ExtensionPanels")
		for _, view: { any } in { { 800, 360, true } :: { any }, { 1280, 720, false }, { 640, 339, true } } do
			local width, height = view[1], view[2]
			local x, y, w, h = EP.shellSheet(width, height, view[3])
			local sheet = { x = x, y = y, width = w, height = h }
			local close = { x = x + w - 6 - 44, y = y, width = 44, height = 44 }
			local header = { x = x, y = y, width = w, height = 44 }
			local skip = Shell.cornerButton(width, height, 96, 44, sheet, 64, 44)
			assert(Shell.inside(skip, width, height), "skip inside at " .. width)
			assert(skip.width >= 64 and skip.height >= 44, "skip stays a touch target")
			assert(not Shell.overlaps(skip, close), "skip clear of the close X at " .. width)
			assert(not Shell.overlaps(skip, header), "skip clear of the header at " .. width)
			local free = Shell.cornerButton(width, height, 96, 44, nil, 64, 44)
			assert(free.x + free.width <= width - 8 and free.y < height / 2, "top-right without a sheet")
		end
	end,
	-- studio-after defect 13: the PC quest card was a dark box ~3x its two lines. The text sizes to
	-- its lines at a fixed label size, capped at the slot.
	["quest card text is as tall as its lines"] = function()
		local roblox: any = require("@lune/roblox")
		local fs = require("@lune/fs")
		local luau = require("@lune/luau")
		local shell = luau.load(fs.readFile("genres/survival-coop/module/HudShell.luau"), {
			environment = table.clone(roblox),
		})()
		local label = roblox.Instance.new("TextLabel")
		label.TextScaled, label.Size = true, roblox.UDim2.fromScale(1, 1)
		local fit = roblox.Instance.new("UITextSizeConstraint")
		fit.Parent = label
		shell.fitQuestText(label, 86, false)
		assert(not label.TextScaled and label.TextSize == shell.QUEST_TEXT.pc, "fixed label size on PC")
		assert(label.Size.Y.Scale == 0 and label.AutomaticSize == roblox.Enum.AutomaticSize.Y, "height follows lines")
		assert(label:FindFirstChildOfClass("UITextSizeConstraint") == nil, "no scaled-text cap left")
		assert(label:FindFirstChild("QuestCap").MaxSize.Y == 86, "never taller than the slot")
		shell.fitQuestText(label, nil, true)
		assert(label.TextSize == shell.QUEST_TEXT.touch, "touch size")
		local opening = fs.readFile("games/robango-island/src/shared/OpeningClient.luau")
		assert(not string.find(opening, "tracker.TextScaled, tracker.TextWrapped = true", 1, true), "no scaled tracker")
		assert(string.find(opening, "HudShell.fitQuestText(tracker,", 1, true), "the opening tracker uses it")
		assert(string.find(opening, "M.placeSkip(skip, gui,", 1, true), "the cold-open skip is placed per frame")
	end,
}
