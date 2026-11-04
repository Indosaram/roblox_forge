--!strict
-- JourneyIsland (journey6h.spec): legs 2-4 of the simulated player. Home, the start guides, the
-- harbor, route 1's drift isles (a1.s1-s4), the town by chart, then the grind to the time budget.
-- One loop: each turn reads the HUD objective line (and, on a drift isle, the stage line), picks
-- the affordance the line names and performs it through the surface the client shows; when the
-- line names nothing the player can do here, the turn records a stall with the owning file:line.
local Content: any = require("./src/shared/SurvivalContent")
local Kit = require("./JourneyKit.fixture")
local GuideEvents = require("../../genres/survival-coop/module/GuideEvents")

local M = {}
M.unload = nil :: (() -> ())?
local count, anchorOf, owner = Kit.count, Kit.anchorOf, Kit.owner

-- First `n` characters of a shown text (UTF-8 safe: JSON rejects a cut code point).
local function cut(value: any, n: number): string
	local text = tostring(value)
	local ok, stop = pcall(utf8.offset, text, n + 1)
	return if ok and stop then string.sub(text, 1, stop - 1) else text
end

function M.run(host: any, p: any, options: any?): any
	local ACTOR = p.ACTOR
	local debug = options and options.debug
	local function extensions(): any
		return host.session.snapshot(ACTOR).survivalExtensions or {}
	end
	local function trip(): any
		local document = host.factory.expeditionStore.snapshot(ACTOR)
		return document and document.archipelago
	end
	local function anchor(id: string): any
		return anchorOf(p.layout(), id)
	end
	local function layoutOf(id: string): any
		for _, l in Content.layouts do
			if l.id == id then
				return l
			end
		end
		return nil
	end
	-- A travel the server accepted: the next place is a new server and a new client.
	local function travelled(): boolean
		local travel = host.pendingTravel
		if not travel then
			return false
		end
		host.pendingTravel = nil
		p.event("travel", travel)
		local to = travel.to
		local spawn: any = Content.homePolicy.dock
		local role = to
		if to == "archipelago" then
			local t = trip()
			local l = t and layoutOf(t.templateId .. ".s" .. tostring(t.stage))
			spawn = (l and anchorOf(l, "entry")) or { x = 0, y = 4, z = 0 }
		elseif to ~= "home" then
			role = "rw." .. to
			local l = layoutOf(role)
			spawn = (l and anchorOf(l, "entry")) or spawn
		end
		p.enter(role, spawn)
		p.milestone("arrive:" .. tostring(host.layoutId))
		return true
	end
	-- travelAfterCommand defers the handoff to the Lune scheduler: tick until it lands (bounded).
	local function settleTravel(): boolean
		for _ = 1, 6 do
			if travelled() then
				return true
			end
			p.wait(1)
		end
		return false
	end
	local function clickNamed(name: string): boolean
		local item = p.find(name)
		if item then
			p.click(item)
			return true
		end
		return false
	end
	local skipGuide: { [string]: boolean } = {}
	local routeVisits: { [string]: number } = {}
	-- The next open guide objective, as CharacterText.guideObjective picks it for the HUD line.
	local function guideTarget(): (any, any)
		local ch = extensions().character or {}
		local done, progress = ch.definitions or {}, ch.progress or {}
		local level, grade = ch.level or 1, math.floor((ch.points or 0) / 100)
		for _, g in GuideEvents.visible(Content, true) do
			if not done[g.id] and not skipGuide[g.id] and GuideEvents.open(g, level, grade) then
				for _, o in g.objectives do
					if (progress[o.id] or 0) < o.quantity then
						return g, o
					end
				end
			end
		end
		return nil, nil
	end
	-- The chart isle (not this one) whose wildlife drops `item` or a raw input of the recipe making
	-- it, when no creature here does; nil otherwise.
	local function dropIsle(item: string, depth: number?): string?
		local droppers: { [string]: boolean } = {}
		for _, row in Content.wildlifeDetails or {} do
			for _, drop in row.dropReservoirs or {} do
				if drop.item == item then
					droppers[row.id] = true
				end
			end
		end
		if next(droppers) then
			for _, npc in host.factory.services.survivalWildlife.snapshot(ACTOR) or {} do
				if droppers[npc.catalogId] then
					return nil
				end
			end
			for _, row: any in require("./src/shared/SeaChart").ISLANDS :: { any } do
				local l = row.role and layoutOf("rw." .. row.role)
				if l and "rw." .. row.role ~= host.layoutId then
					for _, spawn in l.spawns or {} do
						if droppers[spawn.speciesId] then
							return row.id
						end
					end
				end
			end
			return nil
		end
		if (depth or 0) >= 2 then
			return nil
		end
		for _, r in Content.recipes do
			if r.outputs[1] and r.outputs[1].item == item then
				for _, input in r.inputs do
					if count(p.bag().items, input.item) < input.quantity then
						local isle = dropIsle(input.item, (depth or 0) + 1)
						if isle then
							return isle
						end
					end
				end
			end
		end
		return nil
	end
	local function recipeFor(target: string): any
		for _, r in Content.recipes do
			if r.id == target then
				return r
			end
		end
		for _, r in Content.recipes do
			if r.outputs[1] and r.outputs[1].item == target then
				return r
			end
		end
		return nil
	end

	-- Harbor sale: Sella's prompt (dialogue -> market service) or the market tile; the solo sheet's
	-- one primary sells the picked bag stack to the harbor.
	local function sellAtHarbor(catalogId: string?, steps: number?): (boolean, string)
		local sella = anchor("npc.sella")
		if sella then
			p.walk(sella, 4)
		end
		local opened = false
		for _, prompt in p.prompts() do
			if prompt:GetAttribute("ForgeMarket") == true or prompt:GetAttribute("ForgePanel") == "market" then
				p.trigger(prompt)
				opened = true
				break
			end
		end
		local how = if opened then "sella-prompt" else "none"
		for _, row in p.findPrefix("Row") do
			if
				row.ClassName == "TextButton" and (string.find(row.Text, "장터") or string.find(row.Text, "Market"))
			then
				p.click(row)
				how ..= "+dialogue"
				break
			end
		end
		if not p.find("Primary") then
			p.closeSheets()
			if p.openTile("market") then
				how ..= "+tile"
			end
		end
		local before = p.personal().balance or 0
		if catalogId then
			-- The tile whose shown name is the item's (TileName), as the player reads it.
			local shownName = require("./PackText.fixture").names("ko-kr")[catalogId] or catalogId
			for _, tile in p.findPrefix("SellTile-") do
				local label = nil
				for _, child in tile:GetDescendants() do
					label = if child.Name == "TileName" then child else label
				end
				if label and label.Text == shownName then
					p.click(tile)
					break
				end
			end
			for _ = 1, steps or 0 do
				for _, button in p.findPrefix("Button") do
					if button.Text == "+10" then
						p.click(button)
						break
					end
				end
			end
		end
		local primary = p.find("Primary")
		if not primary then
			local names = {}
			for _, item in p.h().playerGui:GetDescendants() do
				if p.shown(item) and item.ClassName == "TextButton" then
					table.insert(names, item.Name .. "=" .. cut(item.Text, 30))
				end
			end
			p.event("market-shown", names)
		end
		if primary then
			p.click(primary)
		end
		p.closeSheets()
		local after = p.personal().balance or 0
		p.event("harbor-sell", { before = before, after = after, primary = primary ~= nil, how = how })
		return after > before, how
	end

	-- Attack: walk to the nearest live creature of the kind and press the HUD attack (CombatHud's
	-- engage loop sends survival-coop:attack with the creature id).
	local function attack(target: string): (boolean, string?)
		local snapshot = host.factory.services.survivalWildlife.snapshot(ACTOR) or {}
		local best, bestDistance = nil, math.huge
		local at = p.position()
		for id, npc in snapshot do
			if npc.catalogId == target and npc.healthMilli > 0 then
				local d = math.sqrt((npc.home.x - at.x) ^ 2 + (npc.home.z - at.z) ^ 2)
				if d < bestDistance then
					best, bestDistance = id, d
				end
			end
		end
		if not best then
			return false, "NO_TARGET"
		end
		local npc = snapshot[best]
		p.walk(npc.home, 3)
		for _, tag in { "spear", "starter-club", "stone-axe", "bone-knife" } do
			if p.equipFor(tag) then
				break
			end
		end
		local last: string? = nil
		for _ = 1, 90 do
			local result = host.command("attack", { best })
			last = if result.ok then last else result.reason
			p.wait(1)
			local now = (host.factory.services.survivalWildlife.snapshot(ACTOR) or {})[best]
			if not now or now.healthMilli == 0 then
				p.wait(1)
				return true, nil
			end
			local vitals = (p.personal().vitals or {})
			if (vitals.healthMilli or 1) <= 0 then
				return false, "PLAYER_DOWN"
			end
		end
		return false, last or "NOT_KILLED"
	end

	-- One drift isle stage: each objective through the world prompt that serves it.
	local function stage(): string?
		local t = trip()
		if not t or t.status ~= "active" then
			return "inactive"
		end
		local layoutId = t.templateId .. ".s" .. tostring(t.stage)
		p.milestone("stage:" .. layoutId)
		for _, s in Content.stages do
			if s.layout ~= layoutId then
				continue
			end
			for _, o in s.objectives do
				t = trip()
				if t.completed[o.id] then
					continue
				end
				if o.action == "gather" then
					local want = count(p.bag().items, o.target) + o.quantity
					p.gatherItem(o.target, want, 900)
				elseif o.action == "survey" then
					local ids = {}
					for id in host.world.surveyMarkers do
						table.insert(ids, id)
					end
					table.sort(ids)
					for _, id in ids do
						local marker = host.world.surveyMarkers[id]
						p.walk(marker.position, 2)
						for _, prompt in p.prompts() do
							if prompt:GetAttribute("ForgeSurvey") == true then
								p.trigger(prompt)
								break
							end
						end
						p.wait(Content.missionPolicy.surveySeconds + 2)
					end
				elseif o.action == "craft" then
					local recipe = recipeFor(o.target)
					if recipe then
						for _, input in recipe.inputs do
							p.gatherItem(input.item, input.quantity, 600)
						end
						if recipe.station then
							local station = anchor("station." .. recipe.station .. ".t1")
							if station then
								p.walk(station, 3)
							end
						end
						local ok, why = p.craft(recipe.id)
						if not ok then
							p.stall(
								"refused",
								layoutId .. " craft " .. recipe.id .. ": " .. tostring(why),
								owner("genres/survival-coop/module/SurvivalHUD.luau", '"Reserve-" .. recipe.id'),
								"the stage craft must be possible at the stage's own station"
							)
						end
					end
				elseif o.action == "rescue" then
					local origin = anchor("objective")
					local offset = Content.missionPolicy.bandageOffset
					p.walk({ x = origin.x + offset.x, y = origin.y, z = origin.z + offset.z }, 2)
					for _, prompt in p.prompts() do
						if prompt.Parent and prompt.Parent.Name == "bandage-claim" then
							p.trigger(prompt)
						end
					end
					p.walk(origin, 2)
					for _, prompt in p.prompts() do
						if prompt.Parent and prompt.Parent.Name == "rescue-treat" then
							p.trigger(prompt)
						end
					end
					-- Escort: walk back to the entry in short legs so the castaway keeps up.
					local entry = anchor("entry")
					for _ = 1, 120 do
						local pos = p.position()
						local dx, dz = entry.x - pos.x, entry.z - pos.z
						local d = math.sqrt(dx * dx + dz * dz)
						if d < 4 then
							break
						end
						local leg = math.min(d, 8)
						p.walk({ x = pos.x + dx / d * leg, y = entry.y, z = pos.z + dz / d * leg }, 0)
						p.wait(1)
					end
					p.wait(4)
					local function open(): boolean
						local now = trip()
						return now ~= nil and now.completed ~= nil and not now.completed[o.id]
					end
					if open() then
						-- The castaway trails followStuds behind and must itself be within followStuds of
						-- the entry: standing on the entry leaves it short. Step past the entry and wait.
						local pos = p.position()
						local fx, fz = entry.x - (origin.x - entry.x), entry.z - (origin.z - entry.z)
						local dx, dz = fx - entry.x, fz - entry.z
						local d = math.max(1, math.sqrt(dx * dx + dz * dz))
						local past = Content.missionPolicy.followStuds - 2
						p.walk({ x = entry.x + dx / d * past, y = entry.y, z = entry.z + dz / d * past }, 0)
						p.wait(4)
						local after = trip()
						p.stall(
							"friction",
							"rescue escort: standing on the entry ("
								.. string.format("%.1f", math.sqrt((pos.x - entry.x) ^ 2 + (pos.z - entry.z) ^ 2))
								.. " studs) left the castaway short; it completes only after walking "
								.. tostring(past)
								.. " studs past the entry"
								.. (if after and after.completed and after.completed[o.id] then "" else " (still open)"),
							owner(
								"core/domain/island/MissionObjectives.luau",
								"distance(escort.position, anchors.entry) <= policy.followStuds"
							),
							"complete the escort when the castaway is within followStuds of the player at the entry (or mark where to stand)"
						)
					end
					local state = trip() or {}
					local near = {}
					for _, prompt in p.prompts() do
						table.insert(near, prompt.Parent and prompt.Parent.Name or "?")
					end
					p.event("rescue", {
						claimed = state.bandageClaimed,
						treated = state.treated,
						escort = state.escort and state.escort.position,
						at = p.position(),
						origin = origin,
						entry = entry,
						near = near,
					})
				elseif o.action == "transport" then
					p.walk(anchor("resources"), 2)
					for _, prompt in p.prompts() do
						if prompt.Parent and prompt.Parent.Name == "cargo-claim" then
							p.trigger(prompt)
						end
					end
					p.walk(anchor("objective"), 2)
					for _, prompt in p.prompts() do
						if prompt.Parent and prompt.Parent.Name == "cargo-deliver" then
							p.trigger(prompt)
						end
					end
					p.wait(2)
				elseif o.action == "hunt" then
					local ok, why = attack(o.target)
					if not ok then
						p.stall(
							"refused",
							layoutId .. " hunt " .. o.target .. ": " .. tostring(why),
							owner("genres/survival-coop/module/ArchipelagoExtension.luau", 'objective.action == "hunt"'),
							"a route-1 player must be able to kill the hunt target"
						)
					end
				end
				p.wait(2)
			end
		end
		t = trip()
		local left = {}
		for _, s in Content.stages do
			if s.layout == layoutId then
				for _, o in s.objectives do
					if not t.completed[o.id] then
						table.insert(left, o.id .. " " .. tostring(t.progress[o.id] or 0) .. "/" .. o.quantity)
					end
				end
			end
		end
		if #left > 0 then
			p.stall(
				"stuck",
				layoutId .. " objectives left: " .. table.concat(left, ", "),
				owner("core/domain/island/MissionObjectives.luau", "function M.apply("),
				"see the refusals recorded for this stage"
			)
			return "stuck"
		end
		p.milestone("cleared:" .. layoutId)
		local exit = anchor("exit")
		-- Walk onto the exit dock's deck (its part, lifted to the ground), not the authored anchor:
		-- on rw.a1.s4 the anchor is 8 studs above the deck and out of the prompt's reach.
		for _, value in host.engine.parts do
			if
				value.ClassName == "ProximityPrompt"
				and value.Name == "ForgeDock"
				and value.Parent
				and value.Parent.Name == "exit"
			then
				local q = value.Parent.Position
				exit = { x = q.X, y = q.Y - 2, z = q.Z }
			end
		end
		if exit then
			p.walk(exit, 3)
		end
		local docked = false
		local near = {}
		for _, prompt in p.prompts() do
			table.insert(near, (prompt.Parent and prompt.Parent.Name or "?") .. ":" .. prompt.Name)
			if prompt.Name == "ForgeDock" and not docked then
				p.trigger(prompt)
				docked = true
			end
		end
		p.event("exit-dock", {
			layout = layoutId,
			exit = exit,
			at = p.position(),
			near = near,
			result = p.h().player:GetAttribute("ForgeTravelResult"),
		})
		if not docked then
			p.openTile("expedition")
			clickNamed("ExpeditionNext")
			clickNamed("TravelConfirm")
		end
		if not settleTravel() then
			local result = p.h().player:GetAttribute("ForgeTravelResult")
			p.stall(
				"refused",
				layoutId .. " exit dock did not travel: " .. tostring(result),
				owner("games/robango-island/src/server/RoleWorld.luau", "local function dock("),
				"the exit dock must sail on once the stage is cleared"
			)
			return "stuck"
		end
		return nil
	end

	-- The sea chart (sea-chart tile): pick an isle marker, then its Sail button. Away from a dock
	-- the button reads 'show the dock' (walk there, press again).
	local function sail(isle: string): (boolean, string?)
		local dock = anchor("entry")
		if host.layoutId == "rw.home" then
			dock = Content.homePolicy.dock
		end
		for attempt = 1, 2 do
			if not p.openTile("sea-chart") then
				return false, "NO_SEA_CHART_TILE"
			end
			if not clickNamed("Isle-" .. isle) then
				p.closeSheets()
				return false, "NO_ISLE_MARKER"
			end
			local button = p.find("Sail")
			local label = button and button.Text or ""
			if button then
				p.click(button)
			end
			p.closeSheets()
			if settleTravel() then
				return true, nil
			end
			if attempt == 1 and dock then
				p.event("sail-walk", { isle = isle, label = label })
				p.walk(dock, 2)
			else
				return false, tostring(p.h().player:GetAttribute("ForgeTravelResult")) .. " [" .. label .. "]"
			end
		end
		return false, "SAIL_FAILED"
	end

	-- An item no node here gives: record that the HUD line names no island, then sail to the chart
	-- isle whose layout has the node (wild isles sail from the harbor only). True when the actor
	-- stays and can gather here; false when it sailed (the caller restarts the turn).
	local function seek(item: string, asker: string): boolean
		if p.nodeFor(item) then
			return true
		end
		local role = host.role
		local isle: string? = nil
		for _, row: any in require("./src/shared/SeaChart").ISLANDS :: { any } do
			local l = row.role and layoutOf("rw." .. row.role)
			for _, node in if l then l.resourceNodes or {} else {} do
				if node.item == item and isle == nil and row.role ~= role then
					isle = row.id
				end
			end
		end
		local Text = require("../../genres/survival-coop/module/CharacterText")
		local label = isle and Text.text("ko-kr", "cli.chart.isle." .. isle)
		local hinted = label ~= nil and string.find(p.objective(), label, 1, true) ~= nil
		local itemName = require("./PackText.fixture").names("ko-kr")[item] or item
		-- A just-completed guide announcement can occupy the slot for this turn; it says
		-- nothing about this item's navigation and is not evidence of a missing island hint.
		if not hinted and string.find(p.objective(), itemName, 1, true) then
			p.stall(
				"friction",
				asker
					.. " needs "
					.. item
					.. " but no node on "
					.. tostring(host.layoutId)
					.. " gives it; the HUD line names no island (nodes on: "
					.. tostring(isle)
					.. ")",
				owner("genres/survival-coop/module/CharacterText.luau", "local function openGuide("),
				"name the island (or the chart pin) in the guide line when the current island has no such node"
			)
		end
		if not isle then
			return true
		end
		local ok, why = sail(isle)
		p.event("sail", { to = isle, ok = ok, reason = why, from = host.layoutId, forItem = item })
		if ok then
			return false
		end
		if role ~= "harbor" then
			p.stall(
				"refused",
				"sea chart sail " .. tostring(host.layoutId) .. " -> " .. isle .. " refused: " .. tostring(why),
				owner("core/domain/island/Topology.luau", "explore10 = { harbor = true, home = true },"),
				"the chart must say 'sail from the harbor' on an isle the current port cannot reach"
			)
			if sail("harbor") then
				return false
			end
		end
		return true
	end

	-- Bag full (a gather answered FULL_WEIGHT/FULL_SLOTS): sell the heaviest stack the harbor buys.
	M.unload = function()
		if not p.bagFull() then
			return
		end
		local heaviest, weight = nil, 0
		for _, stack in p.bag().items do
			local definition = nil
			for _, item in Content.items do
				definition = if item.id == stack.catalogId then item else definition
			end
			local w = stack.quantity * (if definition then definition.weightMilli or 0 else 0)
			if w > weight and (definition and not table.find(definition.tags or {}, "tool")) then
				heaviest, weight = stack, w
			end
		end
		if not heaviest then
			return
		end
		if host.role ~= "harbor" and not sail("harbor") then
			return
		end
		-- One sale per stack (the stepper clamps to the picked stack): sell the item's stacks until a
		-- sale stops paying (the harbor's 200-unit daily cap); the next server tick lands the escrowed grant.
		local total = count(p.bag().items, heaviest.catalogId)
		for _ = 1, 6 do
			local sold, how = sellAtHarbor(heaviest.catalogId, 5)
			p.event("unload", { item = heaviest.catalogId, held = total, sold = sold, how = how })
			if not sold then
				break
			end
		end
		p.clearBagFull()
	end
	local function captureHere(want: string?): boolean
		p.closeSheets()
		if (extensions().taming.captureTools or 0) == 0 then
			if not p.obtain("capture-bola", count(p.bag().items, "capture-bola") + 1, 120) then
				return false
			end
			p.render()
		end
		local h = p.h()
		local pets = (extensions().taming.companions or {}).pets or {}
		local ids = {}
		for id, model in h.creatures or {} do
			if
				model:GetAttribute("ForgeWildlifeKind") == (want or "dodo")
				and not pets[id]
				and (model:GetAttribute("ForgeWildlifeHealthMilli") or 0) > 0
			then
				table.insert(ids, id)
			end
		end
		table.sort(ids)
		local model = h.creatures and h.creatures[ids[1]]
		if not model then
			return false
		end
		local at = model:FindFirstChild("HumanoidRootPart").Position
		p.walk({ x = at.X + 2, y = at.Y, z = at.Z }, 0)
		p.equipFor("bone-knife")
		local combat = h.load("genres/survival-coop/module/CombatHud").start({
			content = Content,
			locale = "ko-kr",
			send = h.captureSend,
			approach = function(goal, _within, arrive)
				p.walk({ x = goal.X + 2, y = goal.Y, z = goal.Z }, 0)
				arrive()
				return true
			end,
			stop = function() end,
			hidden = function()
				return false
			end,
			itemName = function(item)
				return item
			end,
			name = function(kind)
				return kind
			end,
			spare = h.petRing.spare,
		})
		combat.engage(model)
		for _ = 1, 40 do
			if h.petRing.capturable() then
				break
			end
			p.wait(1)
			-- Re-tap after a fleeing grazer breaks the combat chase leash.
			combat.engage(model)
		end
		combat.destroy()
		p.event("capture-weakened", {
			id = ids[1],
			health = model:GetAttribute("ForgeWildlifeHealthMilli"),
			command = p.lastCommand(),
			errors = h.errors,
		})
		for _ = 1, 4 do
			if not h.petRing.capturable() then
				break
			end
			local token = p.find("Token-capture")
			if not token then
				break
			end
			p.click(token)
			p.wait(9) -- explicit game time: stun recovery, not a wall-clock sleep
		end
		return ((extensions().taming.companions or {}).pets or {})[ids[1]] ~= nil
	end
	local function feedCaptured()
		p.openTile("taming")
		for _, verb in { "place-", "train-", "feed-" } do
			local button = p.findPrefix(verb)[1]
			if button then
				p.click(button)
			end
		end
		p.closeSheets()
	end
	-- Taming sheet steps for one pet of `species` ("creature": any pet), pressing only the buttons
	-- the sheet shows: place -> train -> feed during training -> claim -> deploy -> saddle -> ride.
	local function tend(action: string, species: string): boolean
		local rules = Content.progressionPolicy.companion
		local function pet(): (string?, any)
			local pets = (extensions().taming.companions or {}).pets or {}
			local ids = {}
			for id, row in pets do
				if species == "creature" or row.species == species then
					table.insert(ids, id)
				end
			end
			table.sort(ids)
			return ids[1], ids[1] and pets[ids[1]]
		end
		local function press(verb: string, id: string): boolean
			p.closeSheets()
			p.openTile("taming")
			p.render()
			local ok = clickNamed(verb .. "-" .. id)
			p.closeSheets()
			return ok
		end
		for _ = 1, 12 do
			local id, row = pet()
			if not id then
				return false
			end
			local phase = row.phase
			if phase == "Captured" then
				press("place", id)
			elseif phase == "PenPlaced" then
				press("train", id)
				if action == "place-training" then
					return true
				end
			elseif phase == "Taming" then
				if action == "place-training" then
					return true
				end
				if (row.feeds or 0) < rules.feedCount then
					p.obtain(rules.feedItem, rules.feedCount - (row.feeds or 0), 300)
					press("feed", id)
				elseif action == "feed" then
					return true
				elseif not press("claim", id) then
					p.wait(math.ceil(rules.trainingMillis / 1000 / 4))
				end
			elseif action == "tame" or action == "place-training" then
				return true
			elseif phase == "Stored" and action == "saddle" and not row.saddle then
				p.obtain("saddle", 1, 600)
				press("saddle", id)
				return true
			elseif phase == "Stored" then
				press("deploy", id)
			elseif phase == "Deployed" and not row.saddle then
				p.obtain("saddle", 1, 600)
				press("saddle", id)
				if action == "saddle" then
					return true
				end
			elseif phase == "Deployed" then
				press("mount", id)
				return true
			else
				press("recover", id)
				p.wait(30)
			end
		end
		return false
	end
	local soldOnce, townVisited = false, false
	local reentered: string? = nil
	local abandoned: { [string]: boolean } = {}
	local lastKey, same = nil, 0
	local idleGrinds = 0
	local turns = 0
	while host.at.value < p.deadline and turns < 3000 do
		turns += 1
		p.wait(1)
		-- A full bag is sold first: any travel with a gather grant in escrow strands the player.
		if M.unload and p.bagFull() and host.role ~= "archipelago" then
			M.unload()
		end
		-- A modal deliberately hides the objective slot. Dismiss it before reading the next goal.
		p.closeSheets()
		local text = p.objective()
		local role = host.role
		-- A raw string key on the HUD (a guide id outside the guide_gNN rows, e.g. mission rw.m1.*).
		local raw = string.match(text, "guide_[%w_]+")
		if raw then
			p.stall(
				"friction",
				"HUD shows the raw key '" .. raw .. "' in: " .. text,
				owner(
					"genres/survival-coop/module/CharacterText.luau",
					'table.insert(new, M.text(locale, "guide_" .. string.sub(id, 4, 6)))'
				),
				"newGuides must name non-guide definitions (missions rw.mN.*) by their content name, not guide_<id>"
			)
		end
		local key = tostring(host.layoutId) .. "|" .. text .. "|" .. p.level()
		same = if key == lastKey then same + 1 else 0
		lastKey = key
		if debug then
			print("DEBUG turn", p.minutes(), host.layoutId, p.level(), text)
		end
		if same >= 4 then
			p.stall(
				"stuck",
				"objective unchanged for 4 turns in " .. tostring(host.layoutId) .. ": " .. text,
				owner("genres/survival-coop/module/CharacterText.luau", "function M.guideObjective"),
				"the line must name an action the player can take here"
			)
			if M.grind(host, p, extensions, settleTravel) then
				idleGrinds = 0
			else
				idleGrinds += 1
				-- Three idle grinds 10 min apart (past a 30 min route window) with no XP is the true wall.
				if idleGrinds >= 3 then
					p.stall(
						"dead-end",
						"no XP from the board or any node in " .. tostring(host.layoutId) .. " for three grind turns",
						owner("genres/survival-coop/module/CharacterText.luau", "function M.guideObjective"),
						"the HUD line must name a reachable step that pays XP"
					)
					break
				end
				p.wait(600)
			end
			same = 0
		end
		if role == "archipelago" then
			local captureGuide, objective = guideTarget()
			if objective and objective.action == "capture" then
				if captureHere(if objective.target ~= "creature" then objective.target else nil) then
					p.milestone("captured:" .. captureGuide.id)
					if (extensions().character.definitions or {})[captureGuide.id] then
						p.milestone("completed:" .. captureGuide.id)
					end
				end
			elseif objective and objective.action == "feed" and captureGuide.id == "rw.g41.second-pet" then
				feedCaptured()
				if (extensions().character.definitions or {})[captureGuide.id] then
					p.milestone("completed:" .. captureGuide.id)
				end
			end
			local result = stage()
			if result == "stuck" or result == "inactive" then
				p.openTile("expedition")
				clickNamed("ExpeditionHome")
				clickNamed("TravelConfirm")
				local last = p.lastCommand()
				if last and last.action == "survival-coop:party-action" and not last.ok then
					p.stall(
						"dead-end",
						"Expedition > Home > Confirm refused: "
							.. tostring(last.reason)
							.. ' (client sends party-action {home, ""})',
						owner("genres/survival-coop/module/ExpeditionPanels.luau", 'local result = act(verb, "")'),
						"send a non-empty second arg (e.g. the trip id) or relax party-action arg 2 to pattern '.*'"
					)
				end
				if not settleTravel() then
					break
				end
			end
			continue
		end
		local g, o = guideTarget()
		local progressed = false
		if g and o then
			p.milestone("guide:" .. g.id)
			local had = ((extensions().character or {}).progress or {})[o.id] or 0
			if o.action == "capture" then
				-- Ashore, follow the HUD's Route 1 direction through the Routes flow below.
				captureHere(if o.target ~= "creature" then o.target else nil)
			elseif o.action == "feed" and g.id == "rw.g41.second-pet" then
				feedCaptured()
				if (extensions().character.definitions or {})[g.id] then
					p.milestone("completed:" .. g.id)
				end
			elseif
				o.action == "place-training"
				or o.action == "tame"
				or o.action == "saddle"
				or o.action == "ride"
				or (o.action == "feed" and o.target == Content.progressionPolicy.companion.feedItem)
			then
				tend(o.action, if o.action == "feed" then "creature" else o.target)
			elseif o.action == "gather" then
				if not seek(o.target, "guide " .. g.id) then
					continue
				end
				p.gatherItem(o.target, count(p.bag().items, o.target) + o.quantity, 900)
			elseif o.action == "craft" then
				local recipe = if o.target == "axe" then recipeFor("stone-axe") else recipeFor(o.target)
				if recipe then
					-- Make here whatever inputs this island's stations can make before sailing for a
					-- station: the chain otherwise ping-pongs between two islands that each lack one.
					for _, input in recipe.inputs do
						if count(p.bag().items, input.item) < input.quantity then
							p.obtain(input.item, input.quantity, 120)
						end
					end
					-- A creature drop (hide for leather) no creature here gives: sail to a chart isle whose
					-- wildlife carries it, as the player hunts where the animals are.
					local huntIsle = nil
					for _, input in recipe.inputs do
						if count(p.bag().items, input.item) < input.quantity then
							huntIsle = huntIsle or dropIsle(input.item)
						end
					end
					if huntIsle then
						p.event("hunt-route", { recipe = recipe.id, isle = huntIsle, layout = host.layoutId })
						if sail(huntIsle) then
							continue
						end
					end
					local missing = Kit.missingStation(Content.recipes, recipe, function(item: string): number
						return count(p.bag().items, item)
					end, function(kind: string): boolean
						for _, part in
							host.engine.game:GetService("CollectionService"):GetTagged("ForgeSurvivalStation")
						do
							if
								part:IsDescendantOf(host.engine.game:GetService("Workspace"))
								and part:GetAttribute("ForgeStationKind") == kind
							then
								return true
							end
						end
						return false
					end)
					p.event("guide-craft-route", { recipe = recipe.id, missing = missing, layout = host.layoutId })
					local routeKey = g.id .. "|" .. tostring(host.layoutId) .. "|" .. tostring(missing)
					routeVisits[routeKey] = (routeVisits[routeKey] or 0) + 1
					if missing and routeVisits[routeKey] > 3 then
						p.stall(
							"dead-end",
							"craft "
								.. recipe.id
								.. " needs a "
								.. missing
								.. " station; sailing for it keeps returning to "
								.. tostring(host.layoutId),
							owner("genres/survival-coop/module/CharacterText.luau", "function M.guideObjective"),
							"the HUD line must name where the missing station stands (or the station must exist where its inputs are)"
						)
						skipGuide[g.id] = true
						continue
					end
					if missing then
						-- Recipes name their station; the chart's island layouts supply its visible destination.
						for _, row in require("./src/shared/SeaChart").ISLANDS do
							local destination = row.role and layoutOf("rw." .. row.role)
							if destination and anchorOf(destination, "station." .. missing .. ".t1") then
								local ok = sail(row.id)
								if not ok and host.role ~= "harbor" then
									sail("harbor")
								end
								break
							end
						end
						continue
					end
					local here = true
					for _, input in recipe.inputs do
						if count(p.bag().items, input.item) < input.quantity then
							local processed = false
							for _, source in Content.recipes do
								processed = processed or source.outputs[1].item == input.item
							end
							if not processed then
								here = here and seek(input.item, "guide " .. g.id .. " (" .. recipe.id .. " input)")
							end
						end
					end
					if not here then
						continue
					end
					if recipe.station then
						local station = anchor("station." .. recipe.station .. ".t1")
						if station then
							p.walk(station, 3)
						end
					end
					local crafted, why = p.craft(recipe.id)
					if not crafted then
						p.event("guide-craft-failed", { recipe = recipe.id, reason = why, layout = host.layoutId })
					end
				end
			elseif o.action == "place" then
				if host.role ~= "home" then
					if sail("home") then
						continue
					end
				else
					local definition = nil
					for _, structure in Content.structures do
						if structure.id == o.target then
							definition = structure
						end
					end
					if definition then
						local pad = anchor("station-pad")
						if pad then
							p.walk({ x = pad.x, y = pad.y, z = pad.z + 6 }, 0)
						end
						p.closeSheets()
						p.h().hud.open("build")
						p.render()
						if not p.find("Structure-" .. o.target) then
							for _, tab in p.findPrefix("BuildTab-") do
								p.click(tab)
								if p.find("Structure-" .. o.target) then
									break
								end
							end
						end
						clickNamed("Structure-" .. o.target)
						clickNamed("ConfirmPlacement")
						clickNamed("ConfirmPlacement")
						p.closeSheets()
					end
				end
			elseif o.action == "purchase" then
				p.h().hud.open("skills")
				p.render()
				for _, node in Content.skillNodes do
					if node.id == o.target then
						clickNamed("skill-" .. node.category)
						-- The category detail offers its next node, not arbitrary descendants.
						for _ = 1, 200 do
							if (p.personal().progression.paid or {})[node.id] ~= nil then
								break
							end
							local learn = p.findPrefix("learn-")[1]
							if not learn then
								break
							end
							local before = p.personal().progression.version
							p.click(learn)
							if p.personal().progression.version == before then
								-- Train the category's authored entry action through the craft sheet or
								-- practice stand; Learn never bypasses the server's proficiency gate.
								local category = nil
								for _, row in Content.skillCategories do
									if row.id == node.category then
										category = row
									end
								end
								local trained = false
								for _, action in if category then category.entryActions else {} do
									local recipe = recipeFor(action)
									if recipe then
										p.closeSheets()
										local station = recipe.station and anchor("station." .. recipe.station .. ".t1")
										if recipe.station and not station then
											for _, part in host.world.tieredStations or {} do
												if part:GetAttribute("ForgeStationKind") == recipe.station then
													station = {
														x = part.Position.X,
														y = part.Position.Y,
														z = part.Position.Z,
													}
													break
												end
											end
										end
										if recipe.station and not station then
											if sail("home") then
												trained = true
												break
											end
										end
										for _, input in recipe.inputs do
											p.obtain(input.item, input.quantity, 120)
										end
										if station then
											p.walk(station, 3)
										end
										if node.category == "processing" and station then
											p.openTile("processing")
											trained = clickNamed("Start-" .. recipe.id)
											for _ = 1, 3 do
												-- Collect finished jobs before starting more: the workshop holds at most
												-- Workshop.MAX_ACTIVE jobs and refuses JOB_QUEUE_FULL past that.
												local start = p.findPrefix("start-")[1]
												local complete = p.findPrefix("complete-")[1]
												if complete then
													p.click(complete)
												elseif start then
													p.click(start)
												end
												p.wait(math.ceil(recipe.craftMillis / 1000) + 1)
											end
											p.closeSheets()
										else
											trained = p.craft(recipe.id)
										end
										break
									elseif anchor(action) then
										for _, operation in Content.operations do
											if operation.id == action then
												for _, input in operation.inputs do
													p.obtain(input.item, input.quantity, 120)
												end
											end
										end
										p.walk(anchor(action), 2)
										for _, prompt in p.prompts() do
											if prompt:GetAttribute("ForgeOperation") == action then
												p.trigger(prompt)
												trained = true
												break
											end
										end
										break
									end
								end
								if not trained or host.at.value >= p.deadline then
									break
								end
								p.h().hud.open("skills")
								p.render()
								clickNamed("skill-" .. node.category)
							end
						end
						break
					end
				end
				p.closeSheets()
			elseif o.action == "expand" then
				if host.role ~= "home" then
					if sail("home") then
						continue
					end
				else
					p.walk(Content.homePolicy.dock, 2)
					p.openTile("character")
					clickNamed("OpenRank")
					clickNamed("Expand")
					p.closeSheets()
				end
			elseif o.action == "plant" then
				if host.role ~= "home" then
					if sail("home") then
						continue
					end
				else
					local farm = require("../../genres/survival-coop/module/FarmCraftModel")
					local home = extensions().home
					local plots = farm.plots(home, host.at.value)
					local plot = plots[1]
					if plot then
						p.walk(plot.position, 2)
						p.openTile("farm")
						clickNamed("Seed-1-" .. o.target)
						for _, crop in farm.crops(Content) do
							if crop.id == o.target then
								p.closeSheets()
								p.obtain(crop.seed, 1, 300)
								p.obtain("water", 1, 300)
								p.walk(plot.position, 2)
								p.openTile("farm")
								clickNamed("Seed-1-" .. o.target)
								for id, stack in p.bag().items do
									if stack.catalogId == crop.seed or stack.catalogId == "water" then
										clickNamed("Store-" .. id)
									end
								end
								clickNamed("Plant-1")
								break
							end
						end
						p.closeSheets()
					end
				end
			elseif o.action == "harvest" then
				if host.role ~= "home" then
					if sail("home") then
						continue
					end
				else
					local farm = require("../../genres/survival-coop/module/FarmCraftModel")
					for _, plot in farm.plots(extensions().home, host.at.value) do
						if plot.planted and plot.planted.crop == o.target then
							p.wait(plot.remaining)
							p.walk(plot.position, 2)
							p.openTile("farm")
							local harvest = p.findPrefix("Harvest-")[1]
							if harvest then
								p.click(harvest)
							end
							p.closeSheets()
							break
						end
					end
				end
			elseif o.action == "equip" then
				-- The HUD line says Menu > Equipment: select the bag row, then its Equip button.
				if p.obtain(o.target, 1, 300) then
					p.openTile("equipment")
					p.render()
					local equipped = false
					for id, stack in p.bag().items do
						if stack.catalogId == o.target and clickNamed("Equip-" .. id) then
							equipped = true
							break
						end
					end
					p.closeSheets()
					if not equipped then
						p.h().hud.open("bag")
						p.render()
						for id, stack in p.bag().items do
							if stack.catalogId == o.target then
								clickNamed(id)
								if clickNamed("Equip-" .. id) then
									break
								end
							end
						end
						p.closeSheets()
					end
				end
			elseif o.action == "eat" then
				if p.obtain(o.target, 1, 300) then
					p.h().hud.open("bag")
					p.render()
					for id, stack in p.bag().items do
						if stack.catalogId == o.target then
							clickNamed(id)
							clickNamed("Eat-" .. id)
							break
						end
					end
					p.closeSheets()
				end
			elseif o.action == "practice" or o.action == "visit" then
				local facility = if o.action == "visit" then "visitor-portal" else o.target
				local at = anchor(facility)
				if not at and host.role ~= "harbor" then
					if sail("harbor") then
						continue
					end
				elseif at then
					p.walk(at, 2)
					if o.action == "visit" then
						-- The guide's Visit row is the acknowledgement; it is range-gated at this portal.
						p.openTile("guides")
						clickNamed("Objective-" .. o.id)
						p.closeSheets()
						for _, prompt in p.prompts() do
							if
								prompt.Parent
								and prompt.Parent:GetAttribute("ForgeHarborFacility") == "visitor-portal"
							then
								p.trigger(prompt)
								settleTravel()
								break
							end
						end
					else
						for _, operation in Content.operations do
							if operation.id == o.target then
								for _, input in operation.inputs do
									p.obtain(input.item, input.quantity, 300)
								end
							end
						end
						p.walk(at, 2)
						for _, prompt in p.prompts() do
							if prompt:GetAttribute("ForgeOperation") == o.target then
								p.trigger(prompt)
								break
							end
						end
						p.closeSheets()
					end
				end
			elseif o.action == "preview-refund" or o.action == "cancel-preview" then
				p.openTile("character")
				clickNamed("OpenReset")
				p.closeSheets()
				p.openTile("guides")
				clickNamed("Objective-" .. o.id)
				p.closeSheets()
			elseif o.action == "deliver" then
				M.contract(p, extensions)
			elseif o.action == "donate" then
				p.openTile("camp")
				local put = p.findPrefix("PutIn-")[1]
				if put then
					p.click(put)
				end
				p.closeSheets()
			end
			local ch = extensions().character or {}
			progressed = ((ch.progress or {})[o.id] or 0) > had or (ch.definitions or {})[g.id] == true
			if not progressed and o.action ~= "capture" then
				skipGuide[g.id] = true
				p.stall(
					if o.action == "capture" then "dead-end" else "refused",
					"guide "
						.. g.id
						.. " ("
						.. o.action
						.. " "
						.. o.target
						.. ") made no progress in "
						.. tostring(host.layoutId)
						.. "; HUD: "
						.. text,
					owner("genres/survival-coop/module/CharacterText.luau", "local function openGuide("),
					if o.action == "capture"
						then "no capturable creature where the line sends the player; route the line to one or skip it"
						else "the surface the HUD line names must credit the guide"
				)
			end
		end
		if progressed then
			continue
		end
		if role == "harbor" and not soldOnce then
			soldOnce = true
			local sold, how = sellAtHarbor()
			if sold then
				p.milestone("harbor:first-sale")
			else
				p.stall(
					"missing-affordance",
					"harbor sale did not pay (" .. how .. ")",
					owner("genres/survival-coop/module/CrossServerMarketPanel.luau", "local function sell()"),
					"the solo market's one tab must sell bag materials to the harbor"
				)
			end
		end
		local t = trip()
		local live = t and t.status == "active" and host.at.value < (t.expiresAt or math.huge)
		if live and role ~= "archipelago" then
			p.event("trip-active-ashore", { layout = host.layoutId, trip = t.id, index = t.index, stage = t.stage })
			-- archipelago.open runs before the IslandBootstrap edge check, so the refused home depart
			-- left an open trip. The client still shows the Routes card; tap it as a player would.
			if role == "harbor" and reentered ~= t.id then
				reentered = t.id
				p.openTile("routes")
				-- The sheet may reopen on the last refusal overlay; its Retry departs this route.
				local choose = p.find("TravelRetry") or p.find("Route-" .. tostring(t.index))
				if choose and choose.Name == "TravelRetry" then
					p.click(choose)
					choose = nil
				end
				if choose then
					p.click(choose)
					clickNamed("DepartConfirm")
				end
				p.closeSheets()
				if settleTravel() then
					continue
				end
				local last = p.lastCommand()
				local why = if last and last.action == "survival-coop:party-action"
					then tostring(last.reason)
					else "no depart sent"
				p.stall(
					"dead-end",
					"Routes > Route "
						.. tostring(t.index)
						.. " Depart from the harbor refused: "
						.. why
						.. " (an active trip this actor never entered stays open ashore)",
					owner(
						"games/robango-island/src/server/RobangoIslandServer.server.luau",
						"liveWorld.travel = function("
					),
					"check Topology.validateRoleTransition before archipelago.open; the Routes card must show the next window instead of a Depart that refuses"
				)
			end
		end
		if p.level() >= 2 and not live then
			-- Try the shown depart first; the workaround runs only when that is refused by the trip.
			local blocked = false
			if t and t.status == "active" and role == "harbor" and not abandoned[t.id] then
				p.openTile("routes")
				clickNamed("Route-1")
				clickNamed("DepartConfirm")
				p.closeSheets()
				if settleTravel() then
					continue
				end
				local last = p.lastCommand()
				local why = last and last.action == "survival-coop:party-action" and last.reason
				blocked = why == "expedition_active" or why == "route_expired"
			end
			if blocked and t and not abandoned[t.id] then
				-- Workaround, not a client affordance: the expired trip blocks every depart (open answers
				-- expedition_active, admission route_expired) and only the archipelago drift worker resets it.
				abandoned[t.id] = true
				p.stall(
					"dead-end",
					"expired trip (never entered) blocks Route 1 forever ashore: "
						.. "open -> expedition_active, admission -> route_expired; workaround: server archipelago.recover(abandon)",
					owner(
						"games/robango-island/src/server/RobangoIslandServer.server.luau",
						'if trip and trip.status == "active" and now >= trip.expiresAt then'
					),
					"settle an expired trip ashore (recover 'expired' on any role, or in liveWorld.travel before archipelago.open), and validate the role edge before opening"
				)
				local recovered = host.factory.archipelago.recover(ACTOR, "abandon")
				p.event("workaround-recover", { trip = t.id, ok = recovered.ok, reason = recovered.reason })
			end
			p.openTile("routes")
			-- ExpeditionPanels keeps view.kind = "travel" with the failure after the sheet closes, so
			-- the Routes tile reopens on the stale refusal (TravelRetry / TravelBack), not the list.
			local retry = p.find("TravelRetry")
			if retry then
				p.stall(
					"friction",
					"Routes reopens on the last refusal overlay ("
						.. cut((p.find("TravelRefusal") or {}).Text or "", 40)
						.. ") instead of the route list",
					owner(
						"genres/survival-coop/module/ExpeditionPanels.luau",
						'view = { kind = "travel", route = route, failure'
					),
					"reset view to the list when the Routes sheet closes (or when a new window opens)"
				)
				p.click(retry)
				if settleTravel() then
					continue
				end
				clickNamed("TravelBack")
			end
			-- Final ten minutes of a window: the card names the next window; the player waits for it.
			if p.find("RouteNext-1") and role == "harbor" then
				local card = ((extensions().expedition or {}).routes or {})[1] or {}
				local left = (card.expiresAt or 0) - ((extensions().expedition or {}).now or 0)
				p.event("route-wait", { seconds = left, text = cut(p.find("RouteNext-1").Text, 60) })
				p.closeSheets()
				if left > 0 and left <= 600 then
					p.wait(left + 1)
					continue
				end
			end
			-- Off the harbor the card offers 'sail to the harbor' (it opens the sea chart).
			local viaHarbor = p.find("RouteHarbor-1")
			if viaHarbor and role ~= "harbor" then
				p.click(viaHarbor)
				p.closeSheets()
				local ok, why = sail("harbor")
				p.event("sail", { to = "harbor", ok = ok, reason = why, from = host.layoutId, via = "RouteHarbor-1" })
				if ok then
					continue
				end
			end
			local choose = p.find("Route-1")
			local shownRoutes = {}
			for _, item in p.h().playerGui:GetDescendants() do
				if
					p.shown(item)
					and (
						string.find(item.Name, "^Route")
						or string.find(item.Name, "^Depart")
						or string.find(item.Name, "^Travel")
					)
				then
					table.insert(shownRoutes, item.Name .. "=" .. cut(item.Text, 60))
				end
			end
			if choose then
				p.click(choose)
				clickNamed("DepartConfirm")
			end
			for _, item in p.h().playerGui:GetDescendants() do
				if p.shown(item) and (string.find(item.Name, "^Travel") or item.Name == "PartyRefusal") then
					table.insert(shownRoutes, "after:" .. item.Name .. "=" .. cut(item.Text, 80))
				end
			end
			p.event("routes-sheet", shownRoutes)
			p.closeSheets()
			if settleTravel() then
				continue
			end
			p.stall(
				"refused",
				"Routes > Route 1 > Depart from "
					.. tostring(host.layoutId)
					.. " did not travel: "
					.. tostring(p.h().player:GetAttribute("ForgeTravelResult"))
					.. " (command: "
					.. (function()
						local last = p.lastCommand()
						return if last and last.action == "survival-coop:party-action"
							then tostring(last.reason)
							else "none"
					end)()
					.. "; trip "
					.. (if t then tostring(t.status) .. " until " .. tostring(t.expiresAt) else "none")
					.. "); HUD said: "
					.. text,
				owner("genres/survival-coop/module/ExpeditionExtension.luau", "local function depart("),
				"the HUD line / route card must say 'sail to the harbor first' when the route departs only from there"
			)
			if role ~= "harbor" then
				local ok, why = sail("harbor")
				p.event("sail", { to = "harbor", ok = ok, reason = why, from = host.layoutId })
				if ok then
					continue
				end
				p.stall(
					"refused",
					"sea chart sail to the harbor from " .. tostring(host.layoutId) .. " failed: " .. tostring(why),
					owner("games/robango-island/src/shared/SeaChart.luau", "sail.Activated:Connect(function()"),
					"the chart must sail to the harbor from the home dock"
				)
			end
		end
		if not townVisited and role ~= "town" and not live then
			townVisited = true
			local ok, why = sail("town")
			p.event("sail", { to = "town", ok = ok, reason = why, from = host.layoutId })
			if ok then
				continue
			end
		end
		-- Nothing named moves the line here: the player grinds what is shown (contracts board,
		-- route 1 again). Record once per place and line, then keep playing.
		p.stall(
			"dead-end",
			"no shown affordance moves the objective in " .. tostring(host.layoutId) .. ": " .. text,
			owner("genres/survival-coop/module/CharacterText.luau", "function M.guideObjective"),
			"the HUD line must name the next reachable step"
		)
		if M.grind(host, p, extensions, settleTravel) then
			idleGrinds = 0
		else
			idleGrinds += 1
			-- Three idle grinds 10 min apart (past a 30 min route window) with no XP is the true wall.
			if idleGrinds >= 3 then
				p.stall(
					"dead-end",
					"no XP from the board or any node in " .. tostring(host.layoutId) .. " for three grind turns",
					owner("genres/survival-coop/module/CharacterText.luau", "function M.guideObjective"),
					"the HUD line must name a reachable step that pays XP"
				)
				break
			end
			p.wait(600)
		end
	end
	p.event("island-end", { turns = turns, layout = host.layoutId, objective = p.objective() })
	return { turns = turns, role = host.role, layout = host.layoutId, objective = p.objective() }
end
-- The contracts board as shown: Accept the first offer the server takes, gather its goods, Deliver.
function M.contract(p: any, extensions: () -> any)
	p.openTile("contracts")
	local buttons = p.findPrefix("Accept-")
	table.sort(buttons, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	local refused = {}
	for _, accept in buttons do
		local had = 0
		for _, offer in (extensions().contracts or {}).offers or {} do
			had += if offer.accepted then 1 else 0
		end
		p.click(accept)
		local now = 0
		for _, offer in (extensions().contracts or {}).offers or {} do
			now += if offer.accepted then 1 else 0
		end
		if now > had then
			break
		end
		local notice = p.find("Notice")
		table.insert(refused, string.sub(accept.Name, 8) .. "=" .. tostring(notice and notice.Text))
		p.closeSheets()
		p.openTile("contracts")
	end
	if #refused > 0 then
		p.stall(
			"friction",
			"contracts board refuses Accept on " .. #refused .. " listed offers: " .. table.concat(refused, "; "),
			owner("genres/survival-coop/module/ContractsPanel.luau", "for _, offer in state.offers or {} do"),
			"hide or mark locked the offers the server refuses (OUT_OF_ORDER) instead of listing an Accept"
		)
	end
	p.closeSheets()
	for _, offer in (extensions().contracts or {}).offers or {} do
		if offer.accepted then
			for _, need in offer.deliver do
				p.obtain(need.item, need.quantity, 600)
			end
		end
	end
	p.openTile("contracts")
	local deliver = p.findPrefix("Deliver-")[1]
	if deliver then
		p.click(deliver)
	end
	p.closeSheets()
end

-- Grind turn: what the board shows when the HUD line names nothing reachable. Run the contracts
-- board, else gather the nearest node for action XP. Returns false when neither makes progress
-- (the run then ends at its true dead end).
function M.grind(_host: any, p: any, extensions: () -> any, _settle: () -> boolean): boolean
	local before = (p.personal().progression or {}).xp or 0
	local beforeLevel = p.level()
	if M.unload then
		M.unload()
	end
	M.contract(p, extensions)
	for _, item in { "fiber", "wood", "stone", "branch", "berry" } do
		if p.gatherItem(item, count(p.bag().items, item) + 3, 120) then
			break
		end
	end
	p.wait(5)
	local after = (p.personal().progression or {}).xp or 0
	if p.level() > beforeLevel then
		p.milestone("level:" .. p.level())
	end
	return after > before or p.level() > beforeLevel
end

return M
