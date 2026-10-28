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
		assert(r.vitals.height >= Shell.VITALS_MIN_HEIGHT, "vitals holds its three bar rows")
		assert(r.chips.y >= r.vitals.y + r.vitals.height and r.tracker.y >= r.chips.y + r.chips.height, "stacked")
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
		-- The spec's 0.12H vitals rect (111 px tall here) cannot hold the three 24 px bar rows, which spilled
		-- over the coin chip on the phone (staging v25): the panel keeps the spec's top-left corner and
		-- width, grows to VITALS_MIN_HEIGHT, and the chips and tracker stack under it.
		local v = physical(r.vitals, PHONE)
		near("vitals corner", { v[1], v[2], 408, 111 }, { 103, 171, 408, 111 }, 4)
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
		})
		local function beat(): any
			beats[1](1)
			local labels = playerGui:FindFirstChild("ForgeWorldLabels")
			assert(labels and labels:GetAttribute("ForgeLabelCount") == 1, "one node labelled")
			local board = labels:FindFirstChild("WorldLabel")
			assert(board and board.Adornee == node and board.Text.Text == "fiber", "label shows the node")
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
}
