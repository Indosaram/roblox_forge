--!strict
-- R20 travel screen (D2c: the hop showed a flat dark card with the stock Roblox logo; Durango
-- shows the destination and a loading bar). Every island hop shows our travel screen: the
-- destination's name, biome and medallion art over the key art, a progress bar and a tip; it is
-- the TeleportService loading GUI, the arrival place keeps it up, and an in-place island change
-- (a new role world on this server) uses the same screen.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Travel = require("./src/first/TravelScreen")
local Content = require("./src/shared/SurvivalContent")
local SeaChart = require("./src/shared/SeaChart")
local Assets = require("./src/shared/Assets")
local Fixture = require("./PackText.fixture")

local VIEWPORTS = { { 800, 360 }, { 1280, 720 }, { 740, 360 }, { 932, 430 } }
local BOOT = "games/robango-island/src/first/RobangoBoot.client.luau"
local SERVER = "games/robango-island/src/server/RobangoIslandServer.server.luau"

local function overlaps(a: any, b: any): boolean
	return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

local function hangul(text: string): boolean
	for _, code in utf8.codes(text) do
		if code >= 0xAC00 and code <= 0xD7A3 then
			return true
		end
	end
	return false
end

-- Every destination a hop can land on: the chart islands, the drift routes and the other roles.
local function destinations(): { string }
	local list = {}
	for _, island in SeaChart.ISLANDS do
		table.insert(list, island.id)
	end
	for _, role in { "onboarding", "town", "brawl", "team-outpost" } do
		table.insert(list, role)
	end
	return list
end

return {
	["every destination has a name, a biome line and approved medallion art in both languages"] = function()
		local lookup = Fixture.packText
		local function text(key: string, locale: string): string
			return lookup(locale, key) or key
		end
		local seen: { [string]: boolean } = {}
		for _, island in destinations() do
			for _, mode in { "sail", "rift" } do
				local view = Travel.describe(Content, island, mode)
				for _, key in { view.heading, view.name } do
					local en, ko = text(key, "en-us"), text(key, "ko-kr")
					assert(type(en) == "string" and en ~= "" and en ~= key, island .. " en " .. key)
					assert(type(ko) == "string" and hangul(ko), island .. " ko " .. key)
				end
				if view.biome then
					assert(text(view.biome, "ko-kr") ~= view.biome, island .. " biome copy " .. view.biome)
				end
				local art = Assets[view.art]
				assert(type(art) == "string" and string.match(art, "^rbxassetid://%d+$"), island .. " art " .. view.art)
				seen[view.art] = true
			end
		end
		local count = 0
		for _ in seen do
			count += 1
		end
		assert(count >= 5, "destinations show distinct medallions: " .. count)
		assert(Travel.describe(Content, "frontier40", "sail").name == "cli.chart.isle.frontier40", "chart name")
		assert(Travel.describe(Content, "drift4", "rift").art == Travel.BIOME_ART.snow, "drift4 is snow")
		assert(Travel.describe(Content, "frontier60", "sail").art == Travel.BIOME_ART.volcano, "caldera is volcano")
		for _, key in Travel.TIP_KEYS do
			assert(text(key, "ko-kr") ~= key, "tip " .. key)
		end
		assert(text("cli.travel.loading", "ko-kr") ~= "cli.travel.loading", "status line")
	end,
	["the server value round-trips: drift isles by route, mode, serial"] = function()
		local info = assert(Travel.parse(Travel.encode("archipelago", 3, "rift", 7)), "parse")
		assert(info.island == "drift3" and info.mode == "rift" and info.serial == "7", "drift route 3")
		info = assert(Travel.parse(Travel.encode("town", nil, "sail", 8)), "parse town")
		assert(info.island == "town" and info.mode == "sail", "town by sail")
		assert(Travel.parse(nil) == nil and Travel.parse("") == nil, "cleared value")
		assert(Travel.parse("town|walk|1") == nil, "unknown mode refused")
		assert(
			Travel.encode("home", nil, "sail", 1) ~= Travel.encode("home", nil, "sail", 2),
			"serial keeps hops distinct"
		)
	end,
	["the screen fits the phone and PC: text >= 14 px, nothing overlaps or leaves the view"] = function()
		for _, size in VIEWPORTS do
			local w, h = size[1], size[2]
			local rects = Travel.layout(w, h, 58)
			local names = { "art", "heading", "name", "biome", "tip", "status", "bar" }
			for _, name in names do
				local r = assert(rects[name], name)
				assert(r.x >= 0 and r.y >= 0 and r.x + r.width <= w and r.y + r.height <= h, name .. " inside " .. w)
				assert(r.width > 0 and r.height > 0, name .. " has area")
				if r.textSize then
					assert(r.textSize >= Travel.MIN_TEXT, name .. " text " .. r.textSize .. " at " .. w)
				end
			end
			for i = 1, #names do
				for j = i + 1, #names do
					assert(
						not overlaps(rects[names[i]], rects[names[j]]),
						names[i] .. " overlaps " .. names[j] .. " at " .. w
					)
				end
			end
			assert(rects.art.y >= 58, "the medallion clears the top bar at " .. w)
			assert(rects.art.width >= 96, "the medallion reads at " .. w .. ": " .. rects.art.width)
			assert(rects.name.textSize and rects.name.textSize >= 28, "the destination name is the headline")
			assert(rects.bar.width >= w * 0.8, "full-width progress bar")
		end
	end,
	["departure fills, an in-place world change and an arrival finish it, a refusal or a timeout drops it"] = function()
		local origin, nextWorld = {}, {}
		-- Departure (teleport loading): rises, never claims done.
		local flow = Travel.flow()
		assert(flow.step(0, origin, true, 1) == false, "idle shows nothing")
		flow.depart(0, origin)
		local last = 0
		for t = 0, 30 do
			assert(flow.step(t, origin, true, 1) == true, "shows while the teleport loads at " .. t)
			assert(flow.progress >= last and flow.progress < Travel.DEPART_CAP, "departure bar at " .. t)
			last = flow.progress
		end
		assert(last > 0.5, "departure bar visibly fills: " .. last)
		-- In place: a new role world replaces the old one; the bar follows its readiness.
		flow = Travel.flow()
		flow.depart(0, origin)
		flow.step(1, origin, false, 0)
		assert(flow.step(2, nil, false, 0) == true, "old world gone, new one not built: still shown")
		assert(flow.step(3, nextWorld, false, 0.5) == true and flow.progress >= Travel.arriveProgress(0.5), "landing")
		assert(flow.step(4, nextWorld, true, 1) == false and flow.progress == 1, "closes on the first ready frame")
		-- Arrival in another place.
		flow = Travel.flow()
		flow.arrive(0)
		assert(flow.step(0.5, nextWorld, false, 0.2) == true, "arrival keeps the screen")
		assert(flow.progress >= Travel.DEPART_CAP, "arrival starts where departure stopped")
		assert(flow.step(1, nextWorld, true, 1) == false, "arrival closes when ready")
		-- Refusal and timeout.
		flow = Travel.flow()
		flow.depart(0, origin)
		flow.cancel()
		assert(flow.step(1, origin, false, 0) == false, "refused route drops the screen")
		flow.depart(0, origin)
		assert(flow.step(Travel.TIMEOUT_SECONDS + 1, origin, false, 0) == false, "a stuck hop never traps the player")
		-- Tips rotate.
		flow.depart(0, origin)
		flow.step(0, origin, false, 0)
		local first = flow.tip
		flow.step(Travel.TIP_SECONDS + 0.1, origin, false, 0)
		assert(flow.tip ~= first, "tips rotate")
	end,
	["wiring: ReplicatedFirst module, SetTeleportGui, arrival hand-over, server publishes every route"] = function()
		local project = serde.decode("json", fs.readFile("games/robango-island/default.project.json"))
		assert(project.tree.ReplicatedFirst.TravelScreen["$path"] == "src/first/TravelScreen.luau", "shipped first")
		local boot = fs.readFile(BOOT)
		assert(
			string.find(boot, "TeleportService.SetTeleportGui, TeleportService, screen.gui", 1, true),
			"teleport GUI"
		)
		local arriving = assert(string.find(boot, "TeleportService:GetArrivingTeleportGui()", 1, true), "arrival")
		local firstWait = assert(string.find(boot, 'WaitForChild("PlayerGui")', 1, true), "boot waits for PlayerGui")
		assert(arriving < firstWait, "the arriving GUI is read before the boot yields")
		assert(string.find(boot, "player:GetAttributeChangedSignal(Travel.ATTRIBUTE)", 1, true), "departure listener")
		assert(string.find(boot, 'workspace:FindFirstChild("ForgeRoleWorld")', 1, true), "in-place world change")
		local server = fs.readFile(SERVER)
		-- Every routing.travel call goes through announceTravel (publish before, clear on refusal).
		local calls, announced = 0, 0
		for _ in string.gmatch(server, "routing%.travel%(") do
			calls += 1
		end
		for _ in string.gmatch(server, "announceTravel%(player,[^\n]*\n%s*return routing%.travel%(") do
			announced += 1
		end
		assert(calls >= 4 and announced == calls, "announced routes " .. announced .. "/" .. calls)
		assert(string.find(server, "player:SetAttribute(TravelScreen.ATTRIBUTE, nil)", 1, true), "refusal clears")
	end,
}
