--!strict
-- C5b (G22): other players are visible. Name tags carry the clan line at the spec type scale,
-- docks/departure posts label their destination with the live player count, and route cards show
-- the count per route. The count is the sum of real per-server MemoryStore rows (SocialPresence).
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local Presence = require("./src/server/SocialPresence")
local WorldText = require("./src/shared/WorldText")
local Shell = require("../../genres/survival-coop/module/HudShell")
local Models = require("../../genres/survival-coop/module/ExpeditionModels")
local Extension = require("../../genres/survival-coop/module/ExpeditionExtension")
local Party = require("../../core/domain/island/Party")
local Content: any = require("./src/shared/SurvivalContent")
local Engine = require("../../cli/forge/fixtures/production-worlds/engine")
local Fixture = require("./PackText.fixture")

local ENUM = { SortDirection = { Ascending = "asc", Descending = "desc" } }

local function player(id: number): any
	local p: any = { UserId = id, attributes = {} }
	function p:SetAttribute(key, value)
		self.attributes[key] = value
	end
	function p:GetAttribute(key)
		return self.attributes[key]
	end
	return p
end

-- A sorted map with TTL on an injected clock (the shape of MemoryStoreSortedMap).
local function memoryMap(clock: { now: number }): any
	local rows: { [string]: { value: any, expires: number } } = {}
	local map: any = { reads = 0 }
	function map:SetAsync(key, value, ttl)
		rows[key] = { value = serde.decode("json", serde.encode("json", value)), expires = clock.now + ttl }
	end
	function map:RemoveAsync(key)
		rows[key] = nil
	end
	function map:GetRangeAsync(_direction, count, lower)
		self.reads += 1
		local keys = {}
		for key, row in rows do
			if row.expires > clock.now and (lower == nil or key > lower.key) then
				table.insert(keys, key)
			end
		end
		table.sort(keys)
		local out = {}
		for index = 1, math.min(count, #keys) do
			table.insert(out, { key = keys[index], value = rows[keys[index]].value })
		end
		return out
	end
	return map
end

local function server(map: any, role: string, jobId: string, people: { any }, extra: any?): (any, any)
	local workspace: any = { attributes = {} }
	function workspace:SetAttribute(key, value)
		self.attributes[key] = value
	end
	function workspace:GetAttribute(key)
		return self.attributes[key]
	end
	local logs = {}
	local env: any = {
		map = map,
		enum = ENUM,
		players = {
			GetPlayers = function()
				return people
			end,
		},
		workspace = workspace,
		role = role,
		jobId = jobId,
		encode = function(value)
			return serde.encode("json", value)
		end,
		log = function(message)
			table.insert(logs, message)
		end,
	}
	for key, value in extra or {} do
		env[key] = value
	end
	local api = Presence.start(env)
	api.logs, api.workspace = logs, workspace
	return api, workspace
end

return {
	["population sums live server rows per island and drops a dead server after the TTL"] = function()
		local clock = { now = 0 }
		local map = memoryMap(clock)
		local a = server(map, "harbor", "job-a", { player(1), player(2), player(3) })
		local b = server(map, "harbor", "job-b", { player(4) })
		local c = server(map, "explore10", "job-c", { player(5), player(6) })
		local home = server(map, "home", "job-h", { player(7) })
		for _, api in { a, b, c, home } do
			api.tick()
		end
		local counts = assert(a.refresh(), "read")
		assert(counts.harbor == 4 and counts.explore10 == 2, "summed per role: " .. serde.encode("json", counts))
		assert(counts.home == nil, "personal homes are never listed")
		local published = serde.decode("json", a.workspace:GetAttribute(Presence.ATTRIBUTE))
		assert(published.harbor == 4, "published as the workspace attribute the clients read")
		-- job-b stops refreshing (crash): its row lives at most TTL seconds.
		clock.now += Presence.TTL - 1
		a.tick()
		c.tick()
		assert(a.counts.harbor == 4, "still inside the TTL")
		clock.now += 2
		a.tick()
		assert(a.counts.harbor == 3, "dead server expired: " .. tostring(a.counts.harbor))
		-- A clean shutdown removes its row at once.
		c.stop()
		a.refresh()
		assert(a.counts.explore10 == nil, "stopped server row removed")
	end,
	["expedition islands list per route and the read pages past one page"] = function()
		assert(Presence.listingKey("archipelago", 3) == "archipelago.3", "route key")
		assert(Presence.listingKey("archipelago", nil) == nil and Presence.listingKey("onboarding") == nil, "private")
		local clock = { now = 0 }
		local map = memoryMap(clock)
		for index = 1, Presence.PAGE + 5 do
			server(map, "archipelago", string.format("job-%04d", index), { player(index) }, { route = 2 }).publish()
		end
		local reader = server(map, "harbor", "reader", {})
		map.reads = 0
		local counts = assert(reader.refresh(), "read")
		assert(counts["archipelago.2"] == Presence.PAGE + 5, "every page summed: " .. tostring(counts["archipelago.2"]))
		assert(map.reads == 2, "two pages read")
	end,
	["malformed or negative rows never add to a count"] = function()
		local summed = Presence.sum({
			{ key = "harbor|a", value = { key = "harbor", players = 2 } },
			{ key = "harbor|b", value = { key = "harbor", players = 1 } },
			{ key = "junk", value = { key = "harbor", players = -1 } },
			{ key = "junk2", value = "text" },
		})
		assert(summed.harbor == 3, "malformed rows are ignored")
	end,
	["a failing MemoryStore read keeps the last counts and logs instead of inventing numbers"] = function()
		local clock = { now = 0 }
		local map = memoryMap(clock)
		local api = server(map, "harbor", "job", { player(1) })
		api.tick()
		assert(api.counts.harbor == 1, "first read")
		map.GetRangeAsync = function()
			error("throttled")
		end
		assert(api.refresh() == nil, "failed read returns nil")
		assert(api.counts.harbor == 1, "last real counts kept")
		assert(string.find(api.logs[#api.logs], "PRESENCE_READ", 1, true), "logged")
	end,
	["clan tags come from membership, are filtered once per clan and never broadcast unfiltered"] = function()
		local clock = { now = 0 }
		local members = { ["1"] = "Tide Riders", ["2"] = "Tide Riders", ["3"] = nil }
		local filtered = 0
		local failing = false
		local people = { player(1), player(2), player(3) }
		local api = server(memoryMap(clock), "harbor", "job", people, {
			membership = function(actor)
				return members[actor]
			end,
			filter = function(text, _userId)
				if failing then
					error("filter down")
				end
				filtered += 1
				return (string.gsub(text, "Riders", "####"))
			end,
		})
		api.tick()
		assert(people[1]:GetAttribute(Presence.CLAN_ATTRIBUTE) == "Tide ####", "filtered text broadcast")
		assert(people[2]:GetAttribute(Presence.CLAN_ATTRIBUTE) == "Tide ####", "same clan")
		assert(people[3]:GetAttribute(Presence.CLAN_ATTRIBUTE) == nil, "no clan, no tag")
		assert(filtered == 1, "one filter call per clan")
		members["1"] = nil
		api.tick()
		assert(people[1]:GetAttribute(Presence.CLAN_ATTRIBUTE) == nil, "leaving clears the tag")
		failing = true
		members["3"] = "Sea Dogs"
		api.tick()
		assert(people[3]:GetAttribute(Presence.CLAN_ATTRIBUTE) == nil, "unfiltered clan text is not broadcast")
		assert(string.find(api.logs[#api.logs], "PRESENCE_CLAN_FILTER", 1, true), "filter failure logged")
	end,
	["name tags read at default zoom on a landscape phone and follow the spec type scale"] = function()
		-- SM-N981N landscape safe height (ui-spec section 5): 411 - 58 = 353 logical px.
		local phone = Shell.nameTag(353, true)
		assert(phone.name >= 14 and phone.tribe >= 13, "phone tag readable: " .. phone.name .. "/" .. phone.tribe)
		assert(phone.name > phone.tribe, "name above the clan line")
		assert(phone.height >= phone.name + phone.tribe, "both lines fit the tag")
		local pc = Shell.nameTag(1022, false)
		assert(pc.name == 18 and pc.tribe == 15, "PC capped at the label/caption px caps")
	end,
	["the HUD shows every player's clan line and labels docks with live counts"] = function()
		local shell = fs.readFile("genres/survival-coop/module/HudShell.luau")
		assert(not string.find(shell, "tribeLine.Visible, tribeLine.Parent = 0.5, own", 1, true), "not own-only")
		assert(string.find(shell, "options.tribeOf(owner)", 1, true), "others read tribeOf")
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, 'other:GetAttribute("ForgeClan")', 1, true), "tribeOf reads the server attribute")
		assert(Presence.CLAN_ATTRIBUTE == "ForgeClan", "same attribute name")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, 'GetAttribute("ForgePopulation")', 1, true), "client reads the published counts")
		assert(Presence.ATTRIBUTE == "ForgePopulation", "same attribute name")
		local serverSource = fs.readFile("games/robango-island/src/server/RobangoIslandServer.server.luau")
		assert(string.find(serverSource, "SocialPresence).start", 1, true), "server starts presence")
		assert(string.find(serverSource, "clanDirectory.membership", 1, true), "clan from the clan directory")
	end,
	["docks and departure posts are world-labelled with name and live count in KO and EN"] = function()
		local engine = Engine.new()
		local world = engine.role.build(
			Content,
			require("./src/shared/SurvivalWorldConfig"),
			require("./src/shared/WildlifePolicy"),
			function()
				return 0
			end,
			"rw.harbor",
			1776
		)
		local workspace = engine.game:GetService("Workspace")
		local labelled: { [string]: boolean } = {}
		local tags = {
			GetTagged = function()
				return {}
			end,
		}
		for _, entry in Shell.collect(workspace, tags) do
			if entry[2] == "dock" then
				labelled[entry[3]] = true
			end
		end
		for _, role in { "home", "explore10", "explore20", "frontier30" } do
			assert(labelled[role], "dock/departure post labelled: " .. role)
		end
		world.destroy()
		local counts = { explore10 = 7 }
		assert(WorldText.population("en-us", "explore10", counts) == "Wilds (Lv 10) · 7 here", "EN")
		assert(WorldText.population("ko-kr", "explore10", counts) == "야생 지대 (레벨 10) · 지금 7명", "KO")
		assert(WorldText.population("en-us", "explore20", counts) == "Deep wilds (Lv 20)", "unknown count: name only")
		assert(WorldText.population("en-us", "explore10", nil) == "Wilds (Lv 10)", "no counts yet: name only")
		-- The shared table mirrors the strings.csv world.population row.
		local row = Fixture.packText("en-us", "world.population")
		assert(row == WorldText.strings.population[1], "EN mirrors strings.csv")
		assert(Fixture.packText("ko-kr", "world.population") == WorldText.strings.population[2], "KO mirrors")
	end,
	["route cards carry the live per-route count and show it in both locales"] = function()
		local facts = { level = 30, developmentRank = 2, instabilityAccess = 1 }
		local asked = {}
		local cards = Extension.withPopulation(Party.routes(Content, facts, 100, 1800), function(listing)
			table.insert(asked, listing)
			return if listing == "archipelago.1" then 5 else nil
		end)
		assert(asked[1] == "archipelago.1" and #asked == #cards, "every route asked by its listing key")
		assert(cards[1].population == 5 and cards[2].population == nil, "unknown stays unknown")
		local _, en = Models.routes("en-us", { now = 100, routes = cards, facts = facts }, {}, function() end)
		local _, ko = Models.routes("ko-kr", { now = 100, routes = cards, facts = facts }, {}, function() end)
		local function has(items: { any }, needle: string): boolean
			for _, item in items do
				if string.find(item.text, needle, 1, true) then
					return true
				end
			end
			return false
		end
		assert(has(en, "5 here now") and has(ko, "지금 5명"), "count shown")
		assert(not has(en, "0 here now"), "no invented zero for an unknown route")
		assert(Extension.withPopulation(cards, nil) == cards, "packs without the port are unchanged")
	end,
}
