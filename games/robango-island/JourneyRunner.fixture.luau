--!strict
-- JourneyRunner (journey6h.spec): the simulated player. Each step reads only what the client shows
-- (the quest card: OpeningTracker / ObjectiveTracker text, the opening waypoint target, the visible
-- menu tiles, sheet buttons, guide rows, ProximityPrompts within reach) and picks the next action
-- from it. Movement is engine.move along a straight walk at Journey.WALK studs/s; content time
-- (craft millis, node respawns, the boat) advances the explicit clock. When no shown affordance
-- moves the objective, the runner records a stall (time, objective ko+en, what was shown, why,
-- owning file:line) and, where a real player could still go on, takes the documented workaround
-- so the rest of the journey is still measured.
local serde = require("@lune/serde")
local Content: any = require("./src/shared/SurvivalContent")
local Scene = require("./src/shared/OpeningScene")
local PackText = require("./PackText.fixture")

local M = {}

-- Milestones the spec asserts at 6ff723b (the known-good prefix, inside the default 0.5 h budget).
-- Grow this as dead ends close.
M.KNOWN_GOOD = {
	"opening:arrive",
	"opening:fiber",
	"opening:hatchet",
	"opening:campfire",
	"depart:onboarding",
	"opening-guide:rw.g01.first-gather",
	"opening-guide:rw.g02.first-axe",
	"arrive:home",
	"arrive:rw.harbor",
	"harbor:first-sale",
	"cleared:rw.a1.s1",
	"cleared:rw.a1.s2",
	"cleared:rw.a1.s3",
	"cleared:rw.a1.s4",
}

local CharacterText = require("../../genres/survival-coop/module/CharacterText")

local Kit = require("./JourneyKit.fixture")
local GatheringClient = require("../../genres/survival-coop/module/GatheringClient")
local weightOf: { [string]: number } = {}
for _, definition in Content.items do
	weightOf[definition.id] = definition.weightMilli or 0
end
M.owner, M.count, M.anchorOf = Kit.owner, Kit.count, Kit.anchorOf

local count, anchorOf = M.count, M.anchorOf

function M.run(Journey: any, options: any): any
	local budget = (options.hours or 6) * 3600
	local host = Journey.new({ locale = "ko-kr" })
	local ACTOR = Journey.ACTOR
	local log: any = { seed = Journey.SEED, actor = ACTOR, pace = {}, stalls = {}, events = {}, worlds = {} }
	local startAt = host.at.value
	log.commands = {}
	host.onCommand = function(request: any, result: any)
		if
			not result.ok
			and (string.find(request.action, "craft", 1, true) or string.find(request.action, "skill", 1, true))
		then
			print(
				"WORKING journey6h craft-command "
					.. serde.encode(
						"json",
						{ action = request.action, args = request.args, reason = result.reason, data = result.data }
					)
			)
		end
		table.insert(log.commands, {
			minutes = math.floor((host.at.value - startAt) / 6 + 0.5) / 10,
			action = request.action,
			args = request.args,
			ok = result.ok,
			reason = result.reason,
		})
	end
	local function minutes(): number
		return math.floor((host.at.value - startAt) / 6 + 0.5) / 10
	end
	local function personal(): any
		return host.personal(ACTOR) or {}
	end
	local function bag(): any
		return (personal().inventory or {}).bag or { items = {} }
	end
	local function level(): number
		return (personal().progression or {}).level or 1
	end
	local function xp(): number
		return (personal().progression or {}).xp or 0
	end
	local reached: { [string]: boolean } = {}
	local function milestone(id: string)
		if reached[id] then
			return
		end
		reached[id] = true
		table.insert(log.pace, { milestone = id, minutes = minutes(), level = level(), xp = xp() })
		print(string.format("WORKING journey6h %6.1f min L%d %s", minutes(), level(), id))
	end
	local function event(kind: string, detail: any?)
		table.insert(log.events, { minutes = minutes(), kind = kind, detail = detail })
		if
			kind == "guide-craft-route"
			or kind == "guide-craft-failed"
			or kind == "craft-unfinished"
			or kind == "obtain-failed"
		then
			print("WORKING journey6h " .. kind .. " " .. serde.encode("json", detail))
		end
	end

	-- The client view ----------------------------------------------------------------------------
	local h: any = nil
	local function render(): any
		h = host.render()
		host.pump()
		return h
	end
	local function shown(item: any): boolean
		local current = item
		while current and current ~= h.playerGui do
			if current.Visible == false or current.Enabled == false then
				return false
			end
			current = current.Parent
		end
		return current == h.playerGui
	end
	local function find(name: string): any
		for _, item in h.playerGui:GetDescendants() do
			if item.Name == name and shown(item) then
				return item
			end
		end
		return nil
	end
	local function findPrefix(prefix: string): { any }
		local out = {}
		for _, item in h.playerGui:GetDescendants() do
			if string.sub(item.Name, 1, #prefix) == prefix and shown(item) then
				table.insert(out, item)
			end
		end
		table.sort(out, function(a, b)
			return a.Name < b.Name
		end)
		return out
	end
	local function objective(): string
		local opening = find("OpeningTracker")
		if opening and opening.Text ~= "" then
			return opening.Text
		end
		local tracker = find("ObjectiveTracker")
		return if tracker then tracker.Text else ""
	end
	local function tiles(): { string }
		local ids = {}
		for _, tile in h.tiles() do
			if tile.Visible then
				table.insert(ids, string.sub(tile.Name, 6))
			end
		end
		return ids
	end
	local function click(button: any)
		h.click(button)
		render()
	end
	local function openTile(id: string): boolean
		local tile = h.menu:FindFirstChild("Dock-" .. id)
		if not tile or not tile.Visible then
			return false
		end
		click(tile)
		return true
	end
	local function closeSheets()
		for _ = 1, 4 do
			local open = h.sheets()
			if #open == 0 then
				break
			end
			click(open[1].close)
		end
		pcall(function()
			h.hud.close()
		end)
		render()
	end

	-- Stall recording ----------------------------------------------------------------------------
	local stallKeys: { [string]: boolean } = {}
	local function stall(kind: string, why: string, owner: string, fix: string, extra: any?)
		local key = kind .. "|" .. why
		if stallKeys[key] then
			return
		end
		stallKeys[key] = true
		local text = objective()
		-- The en line: the same guide objective (ContractsPanel's tracker source) in en-us; a line
		-- from another source (opening, stage tracker) is recorded as shown.
		local enText = text
		local packet = host.session and host.packet()
		local ch = packet
			and packet.snapshots
			and packet.snapshots.survivalExtensions
			and packet.snapshots.survivalExtensions.character
		if ch then
			local ko = CharacterText.guideObjective("ko-kr", Content, ch, PackText.names("ko-kr"), true)
			local from: number?, to: number? = nil, nil
			if ko then
				from, to = string.find(text, ko, 1, true)
			end
			if ko and from and to then
				local en: string = CharacterText.guideObjective("en-us", Content, ch, PackText.names("en-us"), true)
					or ko
				enText = string.sub(text, 1, from - 1) .. en .. string.sub(text, to + 1)
			end
		end
		local row = {
			minutes = minutes(),
			level = level(),
			world = host.layoutId,
			kind = kind,
			objective = { ko = text, en = enText },
			shown = { tiles = tiles(), objective = text },
			why = why,
			owner = owner,
			fix = fix,
			extra = extra,
		}
		if text == "" then
			-- A blank line: name the first hidden ancestor of the quest card (what hid the HUD line).
			for _, item in h.playerGui:GetDescendants() do
				if item.Name == "ObjectiveTracker" then
					local current, hidden = item, {}
					while current and current ~= h.playerGui do
						if current.Visible == false or current.Enabled == false then
							table.insert(hidden, current.Name)
						end
						current = current.Parent
					end
					row.hudHidden = {
						by = hidden,
						text = item.Text,
						menu = h.menu.Visible,
						survivalSheet = h.player:GetAttribute("ForgeSurvivalSheetOpen"),
						hud = h.hud.isOpen(),
						sheets = (function()
							local names = {}
							for _, sheet in h.sheets() do
								table.insert(names, sheet.frame.Name)
							end
							return names
						end)(),
					}
				end
			end
		end
		table.insert(log.stalls, row)
		print(string.format("WORKING journey6h stall @%.1f min [%s] %s (%s)", minutes(), kind, why, owner))
		print(
			string.format(
				"WORKING journey6h cost: %d ticks %.0fs (advance %.0f heartbeat %.0f), %d renders %.0fs (snapshot %.0f push %.0f)",
				host.cost.ticks,
				host.cost.tick,
				host.cost.advance or 0,
				host.cost.heartbeat or 0,
				host.cost.renders,
				host.cost.render,
				host.cost.snapshot or 0,
				host.cost.push or 0
			)
		)
	end

	-- Movement and time --------------------------------------------------------------------------
	local position = { x = 0, y = 5, z = 0 }
	local function walk(to: any, stop: number?)
		local dx, dz = to.x - position.x, to.z - position.z
		local distance = math.sqrt(dx * dx + dz * dz)
		local keep = stop or 3
		if distance > keep then
			local k = (distance - keep) / distance
			position = { x = position.x + dx * k, y = (to.y or 0) + 3, z = position.z + dz * k }
			local seconds = math.ceil((distance - keep) / Journey.WALK)
			-- Coarse server ticks on a long walk (wildlife and vitals integrate the elapsed time).
			local done = 0
			while done < seconds do
				local step = math.min(30, seconds - done)
				host.tick(step)
				done += step
			end
		end
		host.engine.move(ACTOR, position)
		host.tick(1)
	end
	local function wait(seconds: number)
		local whole = math.ceil(seconds)
		-- At most 30 s per tick: Session renews the 120 s profile lease once per advance.
		local step = if whole > 60 then 30 elseif whole > 8 then 5 else 1
		local done = 0
		while done < whole do
			host.tick(step)
			done += step
		end
		render()
	end

	local function enter(role: string, spawn: any)
		local world = host.enter(role, spawn)
		position = { x = spawn.x, y = spawn.y, z = spawn.z }
		table.insert(log.worlds, { minutes = minutes(), world = host.layoutId, role = host.role })
		host.tick(1)
		host.tick(1)
		render()
		return world
	end

	-- World affordances --------------------------------------------------------------------------
	local function layout(): any
		return host.world.layout
	end
	local function nodeAt(nodeId: string): any
		for _, node in host.world.roleSource.nodes do
			if node.id == nodeId then
				return node
			end
		end
		return nil
	end
	local function nodeFor(item: string): any
		-- The nearest live node whose item the player wants (the shell names it on its label).
		local best, bestDistance = nil, math.huge
		local gathering = host.factory.services.survivalGathering.snapshot(ACTOR)
		for _, node in host.world.roleSource.nodes do
			local state = gathering and gathering.nodes[node.id]
			local items = {}
			for _, row in host.world.roleContent.nodes do
				if row.id == node.catalogId then
					for _, harvest in row.harvest do
						items[harvest.item] = true
					end
				end
			end
			if items[item] and state and state.charges > 0 then
				local d = math.sqrt((node.position.x - position.x) ^ 2 + (node.position.z - position.z) ^ 2)
				if d < bestDistance then
					best, bestDistance = node, d
				end
			end
		end
		return best
	end
	-- The hotbar tap (SurvivalHUD equipSlot -> Humanoid:EquipTool): the fixture player has no
	-- Backpack, so the held Tool is registered directly (engine.equip) for the bag item.
	local held: any = nil
	local function equip(catalogId: string): boolean
		-- The hotbar offers only usable tools: a broken (durability 0) or reserved stack is not a slot.
		local itemId: string? = nil
		local carried = bag()
		for id, item in carried.items do
			-- A stack a craft job holds as input (bag reservations) is not offered either.
			local available = item.quantity or 1
			for _, reservation in carried.reservations or {} do
				available -= reservation[id] or 0
			end
			local definition = nil
			for _, row in Content.items do
				if row.id == catalogId then
					definition = row
				end
			end
			if
				item.catalogId == catalogId
				and definition
				and table.find(definition.tags, "tool")
				and (definition.maxDurabilityMilli or 0) > 0
				and (item.durabilityMilli or 0) > 0
				and available > 0
				and (itemId == nil or id < itemId)
			then
				itemId = id
			end
		end
		if not itemId then
			return false
		end
		local character = host.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR)).Character
		-- The held Tool can leave the hand without this cache knowing (equipping gear from the
		-- Equipment sheet, a respawn): reuse it only while it is still in the character.
		if
			held
			and held.item == itemId
			and held.world == host.world
			and held.tool
			and held.tool.Parent == character
		then
			return true
		end
		if held and held.tool then
			pcall(function()
				held.tool:Destroy()
			end)
		end
		-- The hotbar holds only what the world registers as a tool (tool tag, durability, an
		-- unreserved stack); a refusal there is a slot the hotbar would not offer, not a crash.
		local registered, refusal = pcall(host.engine.equip, host.world, ACTOR, itemId)
		if not registered then
			event("equip-refused", { item = catalogId, reason = tostring(refusal) })
			return false
		end
		if options.debug then
			print(
				"DEBUG equip",
				catalogId,
				itemId,
				serde.encode("json", host.world.services.survivalDeath.equipment(ACTOR) or {})
			)
		end
		character = host.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR)).Character
		held = { item = itemId, world = host.world, tool = character:FindFirstChildOfClass("Tool") }
		event("equip", catalogId)
		return true
	end
	local ToolTiers = require("../../genres/survival-coop/module/ToolTiers")
	local function equipFor(required: string): boolean
		for _, item in bag().items do
			if
				item.durabilityMilli > 0
				and ToolTiers.accepts(Content, required, item.catalogId)
				and equip(item.catalogId)
			then
				return true
			end
		end
		return false
	end
	local craftTool: (required: string) -> boolean
	-- Gather: walk to the node and press its ForgeGather prompt (the server gather command).
	local function gather(nodeId: string): any
		local node = nodeAt(nodeId)
		if not node then
			return { ok = false, reason = "NO_NODE" }
		end
		walk(node.position, 2)
		local function press(): any
			local snapshot = host.factory.services.survivalGathering.snapshot(ACTOR)
			return host.command("gather", { node.id, snapshot.version })
		end
		local result = press()
		if options.debug and not result.ok then
			print("DEBUG gather", node.id, result.reason, serde.encode("json", result.data or {}))
		end
		if not result.ok and result.reason == "SKILL_LOCKED" and type(result.data) == "table" then
			-- GatheringClient's refusal names the required skill; use that Skills category's Learn.
			local need = result.data.requirement or result.data
			if type(need.skill) == "string" then
				closeSheets()
				h.hud.open("skills")
				render()
				for _, definition in Content.skillNodes do
					if definition.id == need.skill then
						local category = find("skill-" .. definition.category)
						if category then
							click(category)
						end
						local learn = find("learn-" .. need.skill)
						if learn then
							click(learn)
							host.tick(1)
						end
						break
					end
				end
				closeSheets()
				result = press()
			end
		end
		if not result.ok and result.reason == "TOOL_UNAVAILABLE" and type(result.data) == "table" then
			-- The refusal toast names the tool (GatheringClient "<tool> equip it"); tap it on the hotbar.
			local need = result.data.requirement or result.data
			if
				type(need.tool) == "string" and (equipFor(need.tool) or (craftTool(need.tool) and equipFor(need.tool)))
			then
				result = press()
			end
		end
		if not result.ok and result.reason == "NODE_UNREACHABLE" then
			-- HudShell pick: a NODE_UNREACHABLE answer walks to PICK_STOP (3) and retries once; the
			-- fixture already stands at 2 studs, so step onto the node's own x/z and retry.
			local from = host.world.rootPosition(ACTOR)
			event("node-unreachable", {
				node = node.id,
				at = from and { x = from.X, y = from.Y, z = from.Z },
				target = node.position,
			})
			walk(node.position, 0.5)
			result = press()
		end
		if result.ok or (type(result.data) == "table" and result.data.status == "pending") then
			host.factory.services.survivalGathering.recover(ACTOR, 8)
		end
		-- No render here: the gather loop reads the server bag; the next UI read renders first.
		return result
	end
	local bagFullFlag = false
	local function gatherItem(item: string, want: number, budgetSeconds: number?): boolean
		if bagFullFlag then
			return false
		end
		local deadline = host.at.value + (budgetSeconds or 900)
		while count(bag().items, item) < want and host.at.value < deadline do
			local node = nodeFor(item)
			if not node then
				wait(20)
			else
				local result = gather(node.id)
				if not result.ok and result.reason == "rate limited" then
					wait(2)
					result = gather(node.id)
				end
				-- A full bag is refused before escrow (GatheringRuntime) with the notice GatheringClient
				-- shows ("가방이 가득 찼어요 ... 가방에서 버려"); the player opens the Bag sheet, picks the
				-- heaviest non-tool stack and taps Drop until the press lands. Only when that fails (or the
				-- press answers pending with the grant held in escrow) is it a dead end.
				local blocked = if type(result.data) == "table" then result.reason or result.data.error else nil
				if
					not result.ok
					and type(blocked) == "string"
					and (string.find(blocked, "WEIGHT") or string.find(blocked, "SLOTS"))
				then
					local carried = {}
					for _, stack in bag().items do
						carried[stack.catalogId] = (carried[stack.catalogId] or 0) + stack.quantity
					end
					local notice = GatheringClient.refusalText("ko-kr", result)
					local escrowed = type(result.data) == "table" and result.data.status == "pending"
					local dropped = 0
					if not escrowed and notice and string.find(notice, "버려", 1, true) then
						for _ = 1, 8 do
							local heaviest, weight = nil, 0
							local slotsFull = string.find(blocked, "SLOTS") ~= nil
							local totals: { [string]: number } = {}
							for _, stack in bag().items do
								totals[stack.catalogId] = (totals[stack.catalogId] or 0) + stack.quantity
							end
							for itemId, stack in bag().items do
								local w = stack.quantity * (weightOf[stack.catalogId] or 0)
								if slotsFull then
									-- A full bag of slots frees a slot only when a whole stack goes (Drop + confirm
									-- drops it): the smallest stack of the most-carried material.
									w = totals[stack.catalogId] * 1000 - stack.quantity
								end
								if w > weight and stack.catalogId ~= item and (stack.durabilityMilli or 0) == 0 then
									heaviest, weight = itemId, w
								end
							end
							if not heaviest then
								break
							end
							closeSheets()
							h.hud.open("bag")
							render()
							local cell = find(heaviest)
							if cell then
								click(cell)
							end
							local drop = find("Drop-" .. heaviest)
							if not drop then
								break
							end
							-- Drop asks once; its confirm drops the whole unreserved stack.
							click(drop)
							render()
							local confirm = find("DropConfirm-" .. heaviest)
							if not confirm then
								break
							end
							click(confirm)
							dropped += 1
							-- The HUD sends on a task; the sheet's next Drop is enabled once the answer lands.
							wait(1)
							closeSheets()
							result = gather(node.id)
							if result.ok then
								break
							end
						end
					end
					event("bag-full", {
						item = item,
						node = node.id,
						reason = blocked,
						layout = host.layoutId,
						bag = carried,
						notice = notice,
						drops = dropped,
						landed = result.ok,
					})
					if not result.ok then
						bagFullFlag = true
						stall(
							"dead-end",
							"bag full ("
								.. blocked
								.. ") gathering "
								.. item
								.. (
									if escrowed
										then "; the press answers pending (grant held in escrow), no 'bag full' refusal"
										else "; notice '"
											.. tostring(notice)
											.. "', "
											.. dropped
											.. " Drop taps did not make room"
								),
							M.owner("genres/survival-coop/module/GatheringRuntime.luau", 'result.status = "pending"'),
							"refuse a gather that cannot fit with a visible 'bag full' (no escrow wait) and point at the warehouse / harbor sale"
						)
						return false
					end
				end
				if not result.ok and not (type(result.data) == "table" and result.data.status == "pending") then
					local tools = {}
					for _, stack in bag().items do
						if (stack.durabilityMilli or 0) > 0 and stack.quantity > 0 then
							table.insert(tools, stack.catalogId)
						end
					end
					local need = if type(result.data) == "table" then result.data.requirement else nil
					event("gather-refused", {
						item = item,
						node = node.id,
						reason = result.reason,
						need = need and need.tool,
						tools = tools,
					})
					return false
				end
			end
		end
		render()
		return count(bag().items, item) >= want
	end

	-- Craft: the HUD craft sheet's recipe row, then Reserve/Make (the hand chain runs on delays).
	local craft: (recipeId: string) -> (boolean, string?)
	local crafting: { [string]: boolean } = {}
	local function make(label: string, wanted: (output: string) -> boolean): boolean
		if crafting[label] then
			return false
		end
		crafting[label] = true
		local made = false
		-- A player makes the plainest recipe first: fewest inputs the bag lacks, then no skill node.
		local candidates = {}
		for _, recipe in Content.recipes do
			if wanted(recipe.outputs[1].item) then
				local lacking = 0
				for _, input in recipe.inputs do
					if count(bag().items, input.item) < input.quantity then
						lacking += 1
					end
				end
				local gated = 0
				for _, detail in Content.recipeDetails or {} do
					if detail.id == recipe.id then
						gated = #(detail.skillNodes or {})
					end
				end
				table.insert(candidates, { recipe = recipe, rank = lacking * 10 + gated })
			end
		end
		table.sort(candidates, function(a, b)
			return a.rank < b.rank or (a.rank == b.rank and a.recipe.id < b.recipe.id)
		end)
		for _, candidate in candidates do
			local recipe = candidate.recipe
			do
				local ok, why = craft(recipe.id)
				made = ok
				if not ok then
					event(
						"guide-craft-failed",
						{ recipe = recipe.id, reason = why, layout = host.layoutId, input = label }
					)
				end
				if made then
					break
				end
			end
		end
		crafting[label] = nil
		return made
	end
	craftTool = function(required: string): boolean
		return make(required, function(output: string): boolean
			return ToolTiers.accepts(Content, required, output)
		end)
	end
	-- A drop (hide, bone, meat) of a creature living here: the combat HUD flow, attack until it falls,
	-- then the carcass picker takes that output (carcass-take). False when no such creature is here.
	local function huntDrop(item: string): boolean
		local droppers: { [string]: boolean } = {}
		for _, row in Content.wildlifeDetails or {} do
			for _, drop in row.dropReservoirs or {} do
				if drop.item == item then
					droppers[row.id] = true
				end
			end
		end
		local snapshot = host.factory.services.survivalWildlife.snapshot(ACTOR) or {}
		local best, distance = nil, math.huge
		for id, npc in snapshot do
			if droppers[npc.catalogId] and npc.healthMilli > 0 then
				local d = (npc.home.x - position.x) ^ 2 + (npc.home.z - position.z) ^ 2
				if d < distance then
					best, distance = id, d
				end
			end
		end
		if not best then
			return false
		end
		walk(snapshot[best].home, 3)
		for _, tag in { "spear", "starter-club", "stone-axe", "bone-knife" } do
			if equipFor(tag) then
				break
			end
		end
		for _ = 1, 90 do
			host.command("attack", { best })
			wait(1)
			local now = (host.factory.services.survivalWildlife.snapshot(ACTOR) or {})[best]
			if not now or now.healthMilli == 0 then
				break
			end
			if ((personal().vitals or {}).healthMilli or 1) <= 0 then
				return false
			end
		end
		local body = (host.factory.services.survivalWildlife.snapshot(ACTOR) or {})[best]
		if body then
			walk(body.position or body.home, 2)
		end
		local result = host.command("carcass-take", { best, item })
		event("hunt-drop", { item = item, wild = best, ok = result.ok, reason = result.reason })
		return result.ok == true
	end
	-- What a contract or guide asks the bag to hold: gather it where a node gives it, else craft it.
	local function obtain(item: string, want: number, budgetSeconds: number?): boolean
		local deadline = host.at.value + (budgetSeconds or 900)
		while count(bag().items, item) < want and host.at.value < deadline do
			if nodeFor(item) then
				if not gatherItem(item, want, deadline - host.at.value) then
					return false
				end
			elseif huntDrop(item) then
				continue
			elseif not make(item, function(output: string): boolean
				return output == item
			end) then
				event(
					"obtain-failed",
					{ item = item, want = want, have = count(bag().items, item), layout = host.layoutId }
				)
				return false
			end
		end
		return count(bag().items, item) >= want
	end
	-- A craft collect refused FULL_SLOTS: the bag sheet's Drop (then its confirm) empties the smallest stack
	-- of a plain material (not a tool, not what is being made) so the output gets a slot.
	local function freeSlot(keep: string): boolean
		local before = 0
		for _ in bag().items do
			before += 1
		end
		local smallest, quantity = nil, math.huge
		for itemId, stack in bag().items do
			if stack.catalogId ~= keep and (stack.durabilityMilli or 0) == 0 and stack.quantity < quantity then
				smallest, quantity = itemId, stack.quantity
			end
		end
		if not smallest then
			return false
		end
		closeSheets()
		h.hud.open("bag")
		render()
		local cell = find(smallest)
		if cell then
			click(cell)
		end
		-- Drop asks once; its confirm drops the whole unreserved stack.
		local drop = find("Drop-" .. smallest)
		if drop then
			click(drop)
			render()
			local confirm = find("DropConfirm-" .. smallest)
			if confirm then
				click(confirm)
				wait(1)
			end
		end
		closeSheets()
		local after = 0
		for _ in bag().items do
			after += 1
		end
		event("free-slot", { item = smallest, before = before, after = after })
		return after < before
	end
	local preparing: { [string]: boolean } = {}
	-- The HUD status says "hungry: open the bag and press Eat one"; a player does that before
	-- crafting on (a long practice run starved the actor and every command answered NOT_ALIVE).
	local function eatIfHungry()
		local vitals = personal().vitals or {}
		if (vitals.hungerMilli or 100000) > 40000 then
			return
		end
		local food: { [string]: boolean } = {}
		for _, definition in Content.items do
			if definition.foodEffects and (definition.foodEffects.hungerMilli or 0) > 0 then
				food[definition.id] = true
			end
		end
		h.hud.open("bag")
		render()
		for id, stack in bag().items do
			if food[stack.catalogId] then
				local row = find(id)
				if row then
					click(row)
				end
				local eat = find("Eat-" .. id)
				if eat then
					click(eat)
					event("eat", stack.catalogId)
					break
				end
			end
		end
		closeSheets()
	end
	craft = function(recipeId: string): (boolean, string?)
		if preparing[recipeId] then
			return false, "RECIPE_CYCLE"
		end
		eatIfHungry()
		h.hud.open("craft")
		render()
		local row = find("Recipe-" .. recipeId)
		if not row then
			-- The sheet lists nearby recipes first; its filter toggles to all.
			local filter = find("RecipeFilter")
			if filter then
				click(filter)
				row = find("Recipe-" .. recipeId)
			end
		end
		if not row then
			closeSheets()
			return false, "RECIPE_NOT_LISTED"
		end
		local shownRecipe = row.Text
		click(row)
		-- The recipe row names a missing skill. Find that name on the Skills sheet, then Learn.
		local Locale = require("../../genres/survival-coop/module/SurvivalHUDLocale")
		require("../../genres/survival-coop/module/PackLocale").use(PackText.packText)
		for _, node in Content.skillNodes do
			local skillName = Locale.skillName("ko-kr", node.id)
			if string.find(shownRecipe, skillName, 1, true) then
				print("WORKING journey6h recipe-skill " .. recipeId .. " " .. node.id .. " " .. shownRecipe)
				closeSheets()
				h.hud.open("skills")
				render()
				local category = find("skill-" .. node.category)
				if category then
					click(category)
				end
				local learn = find("learn-" .. node.id)
				if learn then
					click(learn)
					host.tick(1)
				end
				-- Learn stays refused until the category's proficiency is reached; the HUD line names
				-- the practice ("Practice N more times first: <entry action>"), so craft that first.
				local SkillTraining = require("../../genres/survival-coop/module/SkillTraining")
				local practice, practiceUntil = 0, host.at.value + 1800
				while
					learn
					and not ((personal().progression or {}).paid or {})[node.id]
					and practice < 200
					and host.at.value < practiceUntil
				do
					local training = SkillTraining.forNode(Content, personal().progression, node)
					if not training.action or training.action == recipeId or training.count == 0 then
						break
					end
					closeSheets()
					if not craft(training.action) then
						break
					end
					practice += 1
					h.hud.open("skills")
					render()
					local again = find("skill-" .. node.category)
					if again then
						click(again)
					end
					learn = find("learn-" .. node.id)
					if learn then
						click(learn)
						host.tick(1)
					end
				end
				closeSheets()
				h.hud.open("craft")
				render()
				row = find("Recipe-" .. recipeId)
				if row then
					click(row)
				end
				break
			end
		end
		local reserve = find("Reserve-" .. recipeId)
		if not reserve then
			closeSheets()
			return false, "NO_RESERVE_BUTTON"
		end
		local before = 0
		local recipe: any = nil
		for _, r in Content.recipes do
			recipe = if r.id == recipeId then r else recipe
		end
		local output = recipe.outputs[1].item
		-- Only after selecting the shown recipe do its material rows drive the input chain.
		preparing[recipeId] = true
		closeSheets()
		for _, input in recipe.inputs do
			if not obtain(input.item, input.quantity, 300) then
				preparing[recipeId] = nil
				return false, "INPUT_UNAVAILABLE:" .. input.item
			end
		end
		if recipe.station then
			-- World stations are visibly placed, including home structures and higher tiers.
			local station = nil
			local distance = math.huge
			for _, part in host.engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalStation") do
				if
					part:IsDescendantOf(host.engine.game:GetService("Workspace"))
					and part:GetAttribute("ForgeStationKind") == recipe.station
				then
					local at = part.Position
					local d = (at.X - position.x) ^ 2 + (at.Z - position.z) ^ 2
					if d < distance then
						station, distance = { x = at.X, y = at.Y, z = at.Z }, d
					end
				end
			end
			if not station then
				preparing[recipeId] = nil
				return false, "STATION_UNAVAILABLE:" .. recipe.station
			end
			walk(station, 3)
		end
		preparing[recipeId] = nil
		h.hud.open("craft")
		render()
		row = find("Recipe-" .. recipeId)
		if not row then
			local filter = find("RecipeFilter")
			if filter then
				click(filter)
				row = find("Recipe-" .. recipeId)
			end
		end
		if not row then
			closeSheets()
			return false, "RECIPE_NOT_LISTED"
		end
		click(row)
		reserve = find("Reserve-" .. recipeId)
		if not reserve then
			closeSheets()
			return false, "NO_RESERVE_BUTTON"
		end
		before = count(bag().items, output)
		click(reserve)
		if options.debug then
			print("DEBUG craft", recipeId, serde.encode("json", h.hud and nil), #host.delayed, objective())
			for _, e in h.errors do
				print("  client error", e)
			end
			local t = find("MaterialToast")
			print("  toast", t and t.Text)
		end
		-- The hand chain: craft-start after reserve, craft-complete after craftMillis.
		for _ = 1, 12 do
			host.tick(1)
			render()
			if count(bag().items, output) > before then
				break
			end
		end
		-- Station recipes: the job card shows Start / Complete buttons.
		for _ = 1, 6 do
			if count(bag().items, output) > before then
				break
			end
			local start = findPrefix("start-")[1]
			local complete = findPrefix("complete-")[1]
			if start then
				click(start)
			elseif complete then
				click(complete)
				local last = log.commands[#log.commands]
				if last and last.action == "survival-coop:craft-complete" and last.reason == "FULL_SLOTS" then
					freeSlot(output)
					h.hud.open("craft")
					render()
					local again = find("Recipe-" .. recipeId)
					if again then
						click(again)
					end
				end
			end
			wait(math.ceil(recipe.craftMillis / 1000) + 1)
		end
		local ok = count(bag().items, output) > before
		if not ok then
			-- What the sheet showed when the craft did not finish (labels near the recipe).
			local shownText = {}
			for _, item in h.playerGui:GetDescendants() do
				local name = item.Name
				if
					(item.ClassName == "TextLabel" or item.ClassName == "TextButton")
					and shown(item)
					and (
						string.find(name, "Reserve")
						or string.find(name, "Status")
						or string.find(name, "Refus")
						or string.find(name, "Toast")
						or string.find(name, "Need")
						or string.find(name, "start-")
						or string.find(name, "complete-")
						or string.find(name, "Station")
					)
				then
					table.insert(shownText, name .. "=" .. tostring(item.Text))
				end
			end
			event("craft-unfinished", { recipe = recipeId, layout = host.layoutId, shown = shownText })
			-- A job left Reserved holds its inputs (tools included); the card's Cancel releases them.
			local cancel = findPrefix("cancel-")[1]
			if cancel then
				click(cancel)
				host.tick(1)
			end
		end
		closeSheets()
		return ok, if ok then nil else "CRAFT_DID_NOT_FINISH"
	end

	-- Prompts in reach: every ProximityPrompt on the engine workspace within its activation distance.
	local function prompts(): { any }
		local out = {}
		local at = host.world.rootPosition(ACTOR)
		for _, value in host.engine.parts do
			if value.ClassName == "ProximityPrompt" and value.Parent and not value.destroyed then
				local part = value.Parent
				local p = part.Position
				if at and p and value.Enabled ~= false then
					local d = (p - at).Magnitude
					if d <= (value.MaxActivationDistance or 10) + 2 then
						table.insert(out, value)
					end
				end
			end
		end
		return out
	end
	local function trigger(prompt: any)
		local player = host.engine.game:GetService("Players"):GetPlayerByUserId(tonumber(ACTOR))
		prompt.Triggered:Fire(player)
		-- The client side of the same press (ProximityPromptService.PromptTriggered).
		local service = h.game:GetService("ProximityPromptService")
		local mirror = h.new("ProximityPrompt", prompt.Name)
		for _, key in { "ForgePanel", "ForgeDialogue", "ForgeOperation", "ForgeOpeningAction", "ForgeWarehouse" } do
			mirror:SetAttribute(key, prompt:GetAttribute(key))
		end
		service.PromptTriggered:Fire(mirror, h.player)
		render()
	end

	log.opening = M.opening(host, {
		ACTOR = ACTOR,
		enter = enter,
		render = render,
		find = find,
		findPrefix = findPrefix,
		objective = objective,
		click = click,
		walk = walk,
		wait = wait,
		gather = gather,
		gatherItem = gatherItem,
		craft = craft,
		prompts = prompts,
		trigger = trigger,
		milestone = milestone,
		stall = stall,
		event = event,
		bag = bag,
		layout = layout,
		openTile = openTile,
		closeSheets = closeSheets,
		tiles = tiles,
		position = function()
			return position
		end,
		h = function()
			return h
		end,
	}, options)
	if log.opening.step == "done" and host.pendingTravel then
		-- p134 v75 A3: the real opening (starter bag, no guide-driven fiber gather) must finish the first
		-- gather and first axe guides before departure; on staging g01 sat at 'fiber 0/3' for 70 min.
		local document = host.factory.expeditionStore.snapshot(ACTOR)
		local done = if document and document.development then document.development.definitions or {} else {}
		for _, id in { "rw.g01.first-gather", "rw.g02.first-axe" } do
			if done[id] then
				milestone("opening-guide:" .. id)
			end
		end
		local travel = host.pendingTravel
		host.pendingTravel = nil
		event("travel", travel)
		enter(travel.to, Content.homePolicy.dock)
		milestone("arrive:" .. travel.to)
		local island = require("./JourneyIsland.fixture")
		local ok, result = xpcall(island.run, debug.traceback, host, {
			ACTOR = ACTOR,
			deadline = startAt + budget,
			enter = enter,
			render = render,
			find = find,
			findPrefix = findPrefix,
			objective = objective,
			click = click,
			walk = walk,
			wait = wait,
			gather = gather,
			gatherItem = gatherItem,
			craft = craft,
			prompts = prompts,
			trigger = trigger,
			milestone = milestone,
			stall = stall,
			event = event,
			bag = bag,
			level = level,
			personal = personal,
			obtain = obtain,
			bagFull = function(): boolean
				return bagFullFlag
			end,
			clearBagFull = function()
				bagFullFlag = false
			end,
			nodeFor = nodeFor,
			lastCommand = function()
				return log.commands[#log.commands]
			end,
			layout = layout,
			openTile = openTile,
			closeSheets = closeSheets,
			tiles = tiles,
			equipFor = equipFor,
			shown = shown,
			minutes = minutes,
			position = function()
				return position
			end,
			h = function()
				return h
			end,
		}, options)
		if ok then
			log.island = result
		elseif host.stranded then
			-- Session.close refused the leave: the teleport never starts, the player is stuck here.
			log.island = { stranded = host.stranded }
			stall(
				"dead-end",
				"travel off "
					.. tostring(host.stranded.layout)
					.. " refused: "
					.. tostring(host.stranded.reason)
					.. "; a gather grant held in escrow for bag room blocks Session.close / prepareHandoff (drainActor),"
					.. " so docks, chart sails and route departs fail (ItemTransfer: no refund path after escrow)",
				M.owner("core/infra/genre/Session.luau", "local drained = drainActor(id)"),
				"cancel (refund the node) a gather grant that cannot fit the bag instead of holding the handoff;"
					.. " show 'bag full' at the press"
			)
		else
			error(result, 0)
		end
	end
	log.minutes, log.level, log.xp = minutes(), level(), xp()
	log.fun = M.fun(log)
	log.budgetMinutes = budget / 60
	return log
end

-- Fun pacing of a finished journey (.omo/plans/robango-fun-first-6h.md): the longest gap between
-- consecutive milestones, the most successful reserves of one recipe, when the first creature was
-- captured and how long the player was told to wait for a route window.
function M.fun(log: any): any
	local maxGap, gapBefore, previous = 0, nil, 0
	local firstCapture = nil
	for _, row in log.pace do
		if row.minutes - previous > maxGap then
			maxGap, gapBefore = row.minutes - previous, row.milestone
		end
		previous = row.minutes
		if firstCapture == nil and string.sub(row.milestone, 1, 9) == "captured:" then
			firstCapture = row.minutes
		end
	end
	local repeats: { [string]: number } = {}
	local maxRepeat, repeated = 0, nil
	for _, command in log.commands or {} do
		if command.ok and command.action == "survival-coop:craft-reserve" then
			local recipe = tostring((command.args or {})[1])
			repeats[recipe] = (repeats[recipe] or 0) + 1
			if repeats[recipe] > maxRepeat then
				maxRepeat, repeated = repeats[recipe], recipe
			end
		end
	end
	local waitSeconds = 0
	for _, entry in log.events or {} do
		if entry.kind == "route-wait" then
			waitSeconds += tonumber((entry.detail or {}).seconds) or 0
		end
	end
	return {
		maxGapMinutes = math.floor(maxGap * 10 + 0.5) / 10,
		gapBefore = gapBefore,
		maxRepeat = maxRepeat,
		repeatedRecipe = repeated,
		firstCaptureMinutes = firstCapture,
		waitSeconds = waitSeconds,
	}
end

-- Leg 1: the opening, from the cold open to boarding the Gannet.
function M.opening(host: any, p: any, options: any?): any
	local ACTOR = p.ACTOR
	local world = p.enter("rw.onboarding", { x = 0, y = 5, z = 72 })
	local function view(): any
		return world.opening.extension.snapshot(ACTOR)
	end
	local function step(): string?
		local v = view()
		return if v and v.active then v.step else nil
	end
	local seen: { [string]: boolean } = {}
	host.onOpeningStep = function(id: string)
		if not seen[id] then
			seen[id] = true
			p.milestone("opening:" .. id)
		end
	end
	-- The cold open: the client's cinematic plays COLD_OPEN_SECONDS, then sends skip-arrival and
	-- the cold-open-done intent (OpeningClient.endCold). The player watches it.
	p.wait(25)
	local h = p.h()
	local opening = h.panels -- presence check only
	assert(opening ~= nil, "client panels")
	local intent = h.game:GetService("ReplicatedStorage"):FindFirstChild("ForgeOpeningIntent")
	-- endCold(false) sends only the intent; the ExtensionPanels heartbeat sent skip-arrival when the
	-- humanoid landed. The fixture humanoid has no FloorMaterial, so send what that heartbeat sends.
	host.command("tutorial-skip-arrival", {})
	intent:InvokeServer("cold-open-done")
	p.wait(1)
	local guard = 0
	local last, same = nil, 0
	while step() and guard < 400 do
		guard += 1
		p.wait(1) -- one server tick per decision: the director reads fresh facts
		local current = step()
		if not current then
			break
		end
		same = if current == last then same + 1 else 0
		last = current
		if same >= 40 then
			p.stall(
				"stuck",
				"opening step '" .. tostring(current) .. "' did not advance after 40 tries",
				M.owner("games/robango-island/src/shared/OpeningScene.luau", 'id = "' .. tostring(current) .. '"'),
				"see the refusal recorded just before"
			)
			return { step = current }
		end
		local v = view()
		local layout = p.layout()
		local target = Scene.target(v)
		local goal = if target then anchorOf(layout, target) else nil
		if current == "tumble" or current == "dodge" then
			-- Stakes: walk to the next glowing stake and hold its prompt; dodge the boar charges with
			-- the Dodge pebble while it shows.
			local marks = Scene.stakeMarks(v)
			local pulled = false
			for index, mark in marks do
				if mark.prompt then
					local stake = anchorOf(layout, "opening.stake." .. index)
					p.walk(stake, 2)
					p.wait(1.2)
					for _, prompt in p.prompts() do
						if
							prompt.Name == "ForgeOpeningStake"
							and prompt.Parent:GetAttribute("ForgeOpeningStake") == index
						then
							p.trigger(prompt)
							pulled = true
							break
						end
					end
					break
				end
			end
			if not pulled then
				local charge = v.charge
				if charge then
					local now = host.at.value * 1000
					if now < charge.startAt then
						p.wait(math.max(0, (charge.startAt - now) / 1000))
					end
					local dodge = p.find("OpeningDodge")
					if dodge then
						p.click(dodge)
					else
						host.command("dodge", {})
					end
				end
				p.wait(2)
			end
		elseif current == "mirror" then
			-- The mirror card: tap it to dismiss (OpeningClient card.Activated -> mirror-dismiss).
			p.wait(2)
			local card = p.find("OpeningCard")
			if card then
				p.click(card)
			else
				p.wait(6)
			end
		elseif current == "bone" or current == "fiber" or current == "flint" then
			local item = if current == "bone" then "bone" elseif current == "fiber" then "fiber" else "flint"
			local nodeId = Scene.guideNode(v) or target
			local before = count(p.bag().items, item)
			local result = p.gather(nodeId)
			if not result.ok then
				p.stall(
					"refused",
					"gather " .. tostring(nodeId) .. " refused: " .. tostring(result.reason),
					M.owner("games/robango-island/src/shared/OpeningScene.luau", "M.BONE_NODE ="),
					"the guided node must be gatherable by a fresh actor"
				)
				p.wait(30)
			elseif count(p.bag().items, item) == before then
				p.wait(5)
			end
		elseif current == "bone-knife" or current == "hatchet" then
			local recipe = if current == "bone-knife" then "bone-knife" else "stone-axe"
			local ok, why = p.craft(recipe)
			if not ok then
				p.stall(
					"refused",
					"craft " .. recipe .. ": " .. tostring(why),
					M.owner("genres/survival-coop/module/SurvivalHUD.luau", '"Reserve-" .. recipe.id'),
					"craft sheet must list and finish the pinned recipe"
				)
				p.wait(10)
			end
		elseif current == "stream" or current == "camp" then
			if goal then
				p.walk(goal, 4)
			end
			p.wait(1)
		elseif current == "wood" then
			if options and options.debug then
				print("DEBUG wood", count(p.bag().items, "wood"), v.wood, serde.encode("json", v))
			end
			if not p.gatherItem("wood", 7, 600) then
				p.stall(
					"refused",
					"wood x7 for the ridge camp not gatherable",
					M.owner("games/robango-island/src/shared/OpeningScene.luau", 'id = "wood"'),
					"windfall wood must be gatherable with the hatchet"
				)
				return { step = current }
			end
		elseif current == "campfire" then
			if not M.placeCampfire(host, p) then
				return { step = current }
			end
		elseif current == "accept" or current == "deliver" then
			if not M.maritContract(host, p, current) then
				return { step = current }
			end
		elseif current == "windbreak" then
			if not M.windbreak(host, p) then
				return { step = current }
			end
		elseif current == "beacon" then
			p.walk(goal, 3)
			local lit = false
			for _, prompt in p.prompts() do
				if prompt.Name == "ForgeOpeningBeacon" then
					p.wait(2)
					p.trigger(prompt)
					lit = true
				end
			end
			if not lit then
				p.stall(
					"unreachable",
					"beacon prompt not within reach at the beacon anchor",
					M.owner("games/robango-island/src/server/OpeningDirector.luau", '"ForgeOpeningBeacon"'),
					"move the prompt part to the anchor"
				)
				return { step = current }
			end
			p.wait(1)
		elseif current == "board" then
			p.walk(goal, 3)
			p.wait(math.ceil(Scene.BOAT_MILLIS / 1000) + 1)
			-- The waypoint hides at the jetty; the moored Gannet (its tap prompt) is in plain view.
			local hull = world.opening.boat and world.opening.boat.PrimaryPart
			if hull then
				p.walk({ x = hull.Position.X, y = hull.Position.Y, z = hull.Position.Z }, 4)
			end
			local boarded = false
			for _, prompt in p.prompts() do
				if prompt.Name == "ForgeOpeningBoard" then
					p.trigger(prompt)
					local button = p.find("OpeningBoard") or p.findPrefix("Board")[1]
					if button then
						p.click(button)
					else
						-- OpeningClient's board card: the Board pebble (unnamed) sends intent("board").
						intent:InvokeServer("board")
					end
					boarded = true
				end
			end
			if not boarded then
				p.stall(
					"unreachable",
					"Gannet board prompt not within reach of the jetty anchor",
					M.owner("games/robango-island/src/server/OpeningDirector.luau", '"ForgeOpeningBoard"'),
					"the hull prompt must be reachable from opening.jetty"
				)
				return { step = current }
			end
			p.wait(1)
			if host.pendingTravel then
				p.milestone("depart:onboarding")
				return { step = "done" }
			end
		else
			p.wait(1)
		end
	end
	return { step = step() or "done", guard = guard }
end

-- Beat 6: the campfire on the ridge camp grid, paid from the bag (Build sheet card, then Place).
function M.placeCampfire(host: any, p: any): boolean
	local ACTOR = p.ACTOR
	local marit = anchorOf(p.layout(), "npc.marit")
	p.walk({ x = marit.x, y = marit.y, z = marit.z + 6 }, 0)
	local h = p.h()
	if count(p.bag().items, "wood") < 4 then
		p.gatherItem("wood", 4, 600)
	end
	h.hud.open("build")
	p.render()
	local card = p.find("Structure-campfire")
	if not card then
		-- The sheet opens on the first group (shelter); the player looks through the tabs.
		local tapped = {}
		for _, tab in p.findPrefix("BuildTab-") do
			p.click(tab)
			table.insert(tapped, string.sub(tab.Name, 10))
			card = p.find("Structure-campfire")
			if card then
				break
			end
		end
		if card then
			p.stall(
				"friction",
				"build sheet opens on the Shelter tab; the campfire the tracker asks for is under "
					.. tostring(tapped[#tapped])
					.. " (tabs tried: "
					.. table.concat(tapped, ",")
					.. ")",
				M.owner("genres/survival-coop/module/SurvivalHUD.luau", 'local buildGroup = "shelter"'),
				"open the build sheet on the group of the structure the opening/guide asks for (a buildPin like craftPin)"
			)
		end
	end
	if not card then
		local names = {}
		for _, item in h.playerGui:GetDescendants() do
			if
				string.find(item.Name, "^Structure%-")
				or string.find(item.Name, "^BuildTab%-")
				or string.find(item.Name, "^BuildCard%-")
			then
				table.insert(names, item.Name .. "(" .. tostring(item.Visible) .. ")")
			end
		end
		p.event("build-sheet", { names = names, open = h.hud.isOpen() })
	end
	if not card then
		p.stall(
			"missing-affordance",
			"build sheet shows no campfire card",
			M.owner("genres/survival-coop/module/SurvivalHUD.luau", '"Structure-" .. definition.id'),
			"campfire must be on the build sheet at the ridge camp"
		)
		return false
	end
	p.click(card)
	local confirm = p.find("ConfirmPlacement") or p.find("BuildReserve-campfire")
	if not confirm then
		p.stall(
			"missing-affordance",
			"campfire picked but no Place button shows",
			M.owner("genres/survival-coop/module/SurvivalHUD.luau", 'confirmPlacement.Name = "ConfirmPlacement"'),
			"placement bar must show after Build"
		)
		return false
	end
	p.click(confirm)
	-- Reserve then place (the bar's Place sends settlement-reserve, then settlement-place).
	for _ = 1, 3 do
		local again = p.find("ConfirmPlacement") or p.findPrefix("place-")[1]
		if not again then
			break
		end
		p.click(again)
	end
	p.wait(2)
	p.closeSheets()
	local tutorial = host.session.snapshot(ACTOR).survivalExtensions.contracts.tutorial
	if (tutorial.index or 0) <= 4 then
		local toast = p.find("MaterialToast")
		local reason = p.find("PlacementReason")
		p.stall(
			"refused",
			"campfire placement did not declare the settlement: "
				.. tostring(toast and toast.Text or "")
				.. " "
				.. tostring(reason and reason.Text or ""),
			M.owner("genres/survival-coop/module/SurvivalHUD.luau", "local function placeSelected()"),
			"the bar's Place must reserve and place from the bag at the ridge camp"
		)
		return false
	end
	return true
end

-- Beat 6: Marit's request: open her talk prompt -> contracts board -> Accept, then deliver.
function M.maritContract(host: any, p: any, current: string): boolean
	local ACTOR = p.ACTOR
	local marit = anchorOf(p.layout(), "npc.marit")
	p.walk(marit, 4)
	local opened = false
	for _, prompt in p.prompts() do
		if prompt:GetAttribute("ForgePanel") == "contracts" then
			p.trigger(prompt)
			opened = true
			break
		end
	end
	if not opened then
		opened = p.openTile("contracts")
	end
	local offers = host.session.snapshot(ACTOR).survivalExtensions.contracts.offers
	-- A dialogue may open first; its service choice opens the board.
	local service = p.find("Row3") or p.find("Row2")
	if not p.findPrefix("Accept-")[1] and not p.findPrefix("Deliver-")[1] and service then
		p.click(service)
	end
	if current == "accept" then
		local buttons = p.findPrefix("Accept-")
		if #buttons == 0 then
			p.closeSheets()
			p.openTile("contracts")
			buttons = p.findPrefix("Accept-")
		end
		if #buttons == 0 then
			p.stall(
				"missing-affordance",
				"no Accept button on Marit's board",
				M.owner("genres/survival-coop/module/ContractsPanel.luau", '"Accept-"'),
				"contracts board must list the first-day offers"
			)
			return false
		end
		-- Board order (LayoutOrder) top to bottom; a refused row shows its notice, try the next.
		table.sort(buttons, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		local refused = {}
		for _, accept in buttons do
			p.click(accept)
			local tutorial = host.session.snapshot(ACTOR).survivalExtensions.contracts.tutorial
			if (tutorial.index or 0) > 5 or tutorial.complete then
				break
			end
			local notice = p.find("Notice")
			table.insert(refused, string.sub(accept.Name, 8) .. " -> " .. tostring(notice and notice.Text))
			p.closeSheets()
			p.openTile("contracts")
		end
		if #refused > 0 then
			p.stall(
				"friction",
				"Marit's board lists "
					.. #buttons
					.. " Accept buttons but only the first-day order is accepted; refused: "
					.. table.concat(refused, "; "),
				M.owner("genres/survival-coop/module/ContractsPanel.luau", "for _, offer in state.offers or {} do"),
				"list only the contract the opening asks for (or mark the others locked) while the tutorial is on accept-contract"
			)
		end
		p.closeSheets()
		p.wait(1)
		return true
	end
	-- Deliver: gather what the accepted contract asks for, then press Deliver.
	local accepted: any = nil
	for _, offer in offers do
		accepted = if offer.accepted then offer else accepted
	end
	if accepted then
		p.closeSheets()
		for _, need in accepted.deliver do
			if count(p.bag().items, need.item) < need.quantity then
				p.gatherItem(need.item, need.quantity, 900)
			end
		end
		p.walk(marit, 4)
		p.openTile("contracts")
	end
	local deliver = p.findPrefix("Deliver-")[1]
	if not deliver then
		p.stall(
			"missing-affordance",
			"no Deliver button for the accepted contract",
			M.owner("genres/survival-coop/module/ContractsPanel.luau", '"Deliver-"'),
			"accepted contract must show Deliver"
		)
		return false
	end
	p.click(deliver)
	p.closeSheets()
	p.wait(1)
	local tutorial = host.session.snapshot(ACTOR).survivalExtensions.contracts.tutorial
	if not tutorial.complete then
		p.stall(
			"refused",
			"deliver did not complete the tutorial: " .. p.objective(),
			M.owner("genres/survival-coop/module/ContractsPanel.luau", "M.refusal(locale, result.reason"),
			"deliver must succeed once the bag holds the goal"
		)
		return false
	end
	return true
end

-- Beat 7: the windbreak. The tracker says to put materials in at Marit's camp; the camp sheet's
-- Put materials in sends camp-contribute.
function M.windbreak(_host: any, p: any): boolean
	local marit = anchorOf(p.layout(), "npc.marit")
	p.walk(marit, 4)
	if not p.openTile("camp") then
		p.stall(
			"missing-affordance",
			"windbreak step but no camp tile on the menu",
			M.owner("genres/survival-coop/module/CampPanel.luau", "dock.setAvailable"),
			"camp tile must show while the opening asks for the windbreak"
		)
		return false
	end
	if count(p.bag().items, "fiber") < 1 then
		p.gatherItem("fiber", 1, 300)
		p.openTile("camp")
	end
	local put = p.find("PutIn-windbreak")
	if not put then
		p.stall(
			"missing-affordance",
			"camp sheet open, no Put materials in for the windbreak",
			M.owner("genres/survival-coop/module/CampPanel.luau", 'button.Name = "PutIn-" .. row.id'),
			"windbreak row must offer Put materials in"
		)
		p.closeSheets()
		return false
	end
	p.click(put)
	p.closeSheets()
	p.wait(1)
	return true
end

return M
