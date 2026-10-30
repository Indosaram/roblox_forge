--!strict
-- R01 join screen (G14, D2b "no title and no loading screen"): a ReplicatedFirst loading screen
-- whose bar follows real readiness and that closes on the first ready frame, then a title whose
-- one Start tap routes new players (survivor picker, then the opening) and returning players
-- (straight into the saved world). Text >= 14 px and inside the screen at 800x360 and 1280x720.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Flow = require("./src/first/TitleFlow")
local Fixture = require("./PackText.fixture")

local VIEWPORTS = { { 800, 360 }, { 1280, 720 }, { 740, 360 }, { 932, 430 } }

local function signals(over: { [string]: any }?): Flow.Signals
	local s: any = { loaded = false, text = false, queue = 0, ground = false, character = false, hud = false }
	for key, value in over or {} do
		s[key] = value
	end
	return s
end

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

return {
	["the place ships the loading screen in ReplicatedFirst and drops the default one"] = function()
		local project = serde.decode("json", fs.readFile("games/robango-island/default.project.json"))
		local first = assert(project.tree.ReplicatedFirst, "ReplicatedFirst in the place tree")
		assert(first.RobangoBoot["$path"] == "src/first/RobangoBoot.client.luau", "boot LocalScript")
		assert(first.TitleFlow["$path"] == "src/first/TitleFlow.luau", "flow module beside it")
		local boot = fs.readFile("games/robango-island/src/first/RobangoBoot.client.luau")
		local remove = assert(string.find(boot, "ReplicatedFirst:RemoveDefaultLoadingScreen()", 1, true))
		-- Nothing in ReplicatedStorage is waited on before the default screen is gone.
		assert(not string.find(string.sub(boot, 1, remove), "ReplicatedStorage", 1, true), "removed first")
		assert(string.find(boot, "IgnoreGuiInset, gui.ZIndexBehavior = true", 1, true), "full-bleed")
		assert(string.find(boot, "ContentProvider.RequestQueueSize", 1, true), "queue feeds the bar")
		assert(string.find(boot, 'GetAttribute("ForgeSpawnReady")', 1, true), "SpawnGate ground feeds the bar")
		assert(string.find(boot, 'GetAttribute("ForgeHudReady")', 1, true), "client ready feeds the bar")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		local ready = assert(string.find(client, 'player:SetAttribute("ForgeHudReady", true)', 1, true))
		-- The client reports ready only after its HUD, panels and camera exist: no flash of a
		-- half-built HUD under the fade.
		for _, built in { "local panels = ExtensionPanels.start(", "camera = QuarterView.start(", "local hud = " } do
			local at = assert(string.find(client, built, 1, true), built)
			assert(at < ready, built .. " before ForgeHudReady")
		end
	end,
	["the loading screen closes on the first ready frame and its bar follows readiness"] = function()
		local machine = Flow.machine()
		local last = 0
		local frames = {
			signals({ queue = 40 }),
			signals({ loaded = true, queue = 30 }),
			signals({ loaded = true, text = true, queue = 10 }),
			signals({ loaded = true, text = true, queue = 0, ground = true }),
			signals({ loaded = true, text = true, queue = 0, ground = true, character = true }),
		}
		for index, frame in frames do
			assert(machine.step(frame, index * 0.1) == "loading", "still loading at frame " .. index)
			assert(machine.progress >= last and machine.progress < 1, "bar only moves forward, below full")
			last = machine.progress
		end
		assert(last > 0.6, "bar reflects the ready parts: " .. last)
		-- The HUD-ready frame (0.6 s in) closes it at once: no minimum show time.
		local phase =
			machine.step(signals({ loaded = true, text = true, ground = true, character = true, hud = true }), 0.6)
		assert(phase == "title" and machine.progress == 1 and machine.readyAt == 0.6, "closes on ready")
		-- A queue still draining does not hold the player once the world is ready.
		local busy = Flow.machine()
		assert(
			busy.step(signals({ loaded = true, text = true, queue = 25, character = true, hud = true }), 0) == "title",
			"ready ignores the asset queue"
		)
		-- Without the client's ready (a script error) the title still comes after the give-up time.
		local stuck = Flow.machine()
		stuck.step(signals({ loaded = true, text = true }), 0)
		assert(stuck.step(signals({ loaded = true, text = true }), Flow.GIVE_UP_SECONDS - 1) == "loading", "waits")
		assert(stuck.step(signals({ loaded = true, text = true }), Flow.GIVE_UP_SECONDS) == "title", "never traps")
		-- Tips rotate.
		assert(Flow.tipIndex(0, 6) == 1 and Flow.tipIndex(Flow.TIP_SECONDS, 6) == 2, "tip rotates")
		assert(Flow.tipIndex(Flow.TIP_SECONDS * 6, 6) == 1, "tip wraps")
	end,
	["title Start is one tap and routes new and returning players"] = function()
		local machine = Flow.machine()
		assert(not machine.start(), "Start does nothing while loading")
		machine.step(signals({ loaded = true, text = true, character = true, hud = true }), 0)
		assert(machine.start() and machine.phase == "done", "one tap enters")
		assert(not machine.start(), "a second tap is ignored")
		local fresh =
			{ archipelago = { survivor = { preset = "ranger", chosen = false } }, opening = { active = true } }
		local picked =
			{ archipelago = { survivor = { preset = "ranger", chosen = true } }, opening = { active = true } }
		local returning = { archipelago = { survivor = { preset = "scout", chosen = true } } }
		assert(Flow.route(fresh) == "picker", "first join: the survivor picker")
		assert(Flow.route(picked) == "opening", "new player with a survivor: the opening")
		assert(Flow.route(returning) == "resume", "returning player: the saved world, no opening")
		assert(Flow.route({ opening = { active = false } }) == "resume", "finished opening resumes")
		assert(Flow.route(nil) == nil, "no snapshot yet")
		-- Nothing first-join shows under the title; after Start the picker comes before the cold open.
		local held = Flow.gate(false, fresh)
		assert(not held.picker and not held.coldOpen, "title holds picker and opening")
		assert(Flow.gate(true, fresh).picker and not Flow.gate(true, fresh).coldOpen, "picker first")
		assert(Flow.gate(true, picked).coldOpen and not Flow.gate(true, picked).picker, "then the opening")
		local back = Flow.gate(true, returning)
		assert(not back.picker and not back.coldOpen, "returning players go straight in")
		-- The live wiring: the picker and the cold open read the same hold.
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, 'return player:GetAttribute("ForgeTitleDone") ~= true', 1, true), "title hold")
		assert(string.find(client, "return titleHeld() or pickerShown()", 1, true), "cold open waits for both")
		assert(string.find(client, "scoped.held = titleHeld", 1, true), "picker waits for Start")
		local picker = fs.readFile("games/robango-island/src/shared/SurvivorAvatar.luau")
		assert(string.find(picker, "not (ctx.held and ctx.held())", 1, true), "picker honours the hold")
		assert(string.find(picker, "ctx.onRelease(maybeOpen)", 1, true), "picker opens on release")
		local opening = fs.readFile("games/robango-island/src/shared/OpeningClient.luau")
		assert(string.find(opening, "if view.coldOpen and not (ctx.held and ctx.held()) then", 1, true), "cold open")
		local boot = fs.readFile("games/robango-island/src/first/RobangoBoot.client.luau")
		assert(string.find(boot, 'player:SetAttribute("ForgeTitleDone", true)', 1, true), "Start releases")
		assert(
			string.find(boot, "found:Disable()", 1, true) and string.find(boot, "controls:Enable()", 1, true),
			"input"
		)
	end,
	["title and loading text is at least 14 px, on screen and clear of each other in landscape"] = function()
		for _, viewport in VIEWPORTS do
			local width, height = viewport[1], viewport[2]
			local rects = Flow.layout(width, height)
			local label = width .. "x" .. height
			for name, r in rects do
				assert(
					r.x >= 0 and r.y >= 0 and r.x + r.width <= width and r.y + r.height <= height,
					name .. " off " .. label
				)
				if r.textSize then
					assert(r.textSize >= Flow.MIN_TEXT, string.format("%s %d px at %s", name, r.textSize, label))
				end
			end
			for _, name in { "start", "settings" } do
				local r = rects[name]
				assert(r.width >= Flow.MIN_TOUCH and r.height >= Flow.MIN_TOUCH, name .. " touch size " .. label)
				assert(r.y >= Flow.TOP_INSET, name .. " under the topbar " .. label)
			end
			assert(rects.title.y >= Flow.TOP_INSET, "title under the topbar " .. label)
			-- Loading phase and title phase each show a set that never overlaps.
			for _, set in
				{
					{ "title", "tagline", "tip", "status", "bar", "version" },
					{
						"title",
						"tagline",
						"start",
						"settings",
						"version",
					},
				}
			do
				for i = 1, #set do
					for j = i + 1, #set do
						assert(not overlaps(rects[set[i]], rects[set[j]]), set[i] .. " over " .. set[j] .. " " .. label)
					end
				end
			end
		end
	end,
	["title copy is localized from strings.csv in both languages"] = function()
		local text = Fixture.packText
		assert(text("ko-kr", "game_name") == "로방고 섬" and text("en-us", "game_name") == "Robango Island", "name")
		assert(
			text("ko-kr", "cli.title.start") == "시작하기" and text("en-us", "cli.title.start") == "Start",
			"Start"
		)
		local provenance = fs.readFile("games/robango-island/locale/provenance.csv")
		local keys = { "cli.title.tagline", "cli.title.start", "cli.title.settings", "cli.title.loading" }
		for _, key in Flow.TIP_KEYS do
			table.insert(keys, key)
		end
		for _, key in keys do
			local ko, en = text("ko-kr", key), text("en-us", key)
			assert(ko and en and ko ~= "" and en ~= "" and hangul(ko) and not hangul(en), key .. " both locales")
			assert(string.find(provenance, "\n" .. key .. ",original,", 1, true), key .. " provenance")
		end
		for _, path in { "src/first/RobangoBoot.client.luau", "src/first/TitleFlow.luau" } do
			assert(not hangul(fs.readFile("games/robango-island/" .. path)), path .. " carries no copy")
		end
		assert(Flow.locale("en-us", "ko") == "ko-kr" and Flow.locale("ko-kr", "auto") == "ko-kr", "language rule")
		assert(Flow.version(57) == "v57", "version string")
		-- The backdrop is our own store art; nothing in an unpublished place.
		assert(
			Flow.background(132148614756932) == "rbxthumb://type=GameThumbnail&id=132148614756932&w=768&h=432",
			"art"
		)
		assert(Flow.background(0) == nil, "Studio local place: palette only")
		-- p134 v54: the town place showed its own default thumbnail; every role uses the start place's art.
		assert(
			Flow.background(119869707888496, 95467272687768)
				== "rbxthumb://type=GameThumbnail&id=95467272687768&w=768&h=432",
			"town shows the start place's art"
		)
		assert(
			Flow.background(119869707888496, nil) == "rbxthumb://type=GameThumbnail&id=119869707888496&w=768&h=432",
			"no published start place: own thumbnail"
		)
		assert(Flow.background(0, 95467272687768) == nil, "Studio local place stays palette only")
		local server = fs.readFile("games/robango-island/src/server/RobangoIslandServer.server.luau")
		assert(
			string.find(server, 'workspace:SetAttribute("ForgeTitleArtPlace", roles.onboarding)', 1, true),
			"server publishes the start place"
		)
	end,
	-- p134 v49: the Roblox Backpack hotbar (tool tiles) drew over the title and over the bottom of
	-- the bag and craft sheets. It is hidden under the title, shown after Start, hidden again while a
	-- full sheet is open; hiding the CoreGui never unequips the held tool.
	["the backpack hotbar hides under the title and full sheets and returns after Start"] = function()
		local attributes: { [string]: any } = {}
		local watchers: { [string]: { () -> () } } = {}
		local player = {
			GetAttribute = function(_, name: string)
				return attributes[name]
			end,
			SetAttribute = function(_, name: string, value: any)
				attributes[name] = value
				for _, fn in watchers[name] or {} do
					fn()
				end
			end,
			GetAttributeChangedSignal = function(_, name: string)
				return {
					Connect = function(_, fn)
						watchers[name] = watchers[name] or {}
						table.insert(watchers[name], fn)
						return { Disconnect = function() end }
					end,
				}
			end,
		}
		local applied: { boolean } = {}
		Flow.bindBackpack(player, function(shown: boolean)
			table.insert(applied, shown)
		end)
		assert(#applied == 1 and applied[1] == false, "hidden at once under the title")
		player:SetAttribute("ForgeSurvivalSheetOpen", true)
		assert(#applied == 1, "still hidden, no redundant call")
		player:SetAttribute("ForgeSurvivalSheetOpen", false)
		player:SetAttribute("ForgeTitleDone", true)
		assert(applied[#applied] == true, "Start restores the hotbar")
		player:SetAttribute("ForgeSurvivalSheetOpen", true)
		assert(applied[#applied] == false, "the bag or craft sheet hides it")
		player:SetAttribute("ForgeSurvivalSheetOpen", false)
		assert(applied[#applied] == true, "closing the sheet brings it back")
		player:SetAttribute("ForgeExtensionSheetOpen", true)
		assert(applied[#applied] == false, "an extension sheet hides it too")
		-- HUD polish: the shell's own item hotbar replaces the engine bar while it is up.
		player:SetAttribute("ForgeExtensionSheetOpen", false)
		assert(applied[#applied] == true, "back after the extension sheet")
		player:SetAttribute("ForgeHudHotbar", true)
		assert(applied[#applied] == false, "the HUD hotbar hides the engine bar")
		-- The live wiring: the boot applies it to the Backpack CoreGui and never unequips.
		local boot = fs.readFile("games/robango-island/src/first/RobangoBoot.client.luau")
		assert(string.find(boot, "Flow.bindBackpack(player, function(shown: boolean)", 1, true), "bound in the boot")
		assert(
			string.find(boot, "StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, shown", 1, true),
			"applied to the Backpack CoreGui"
		)
		assert(not string.find(boot, "UnequipTools", 1, true), "the held tool stays equipped")
		-- The sheets publish the attributes the binding reads.
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, 'player:SetAttribute("ForgeSurvivalSheetOpen", sheet.frame.Visible)', 1, true), "bag")
		local panels = fs.readFile("genres/survival-coop/module/ExtensionPanels.luau")
		assert(string.find(panels, 'SetAttribute("ForgeExtensionSheetOpen", open', 1, true), "extension sheets")
	end,
	-- p134 v49 (2400x1080, 850x411 logical, top bar 58): the full-screen crop of the 16:9 key art
	-- cut its top, and the ROBANGO wordmark sat under the Roblox top bar.
	["the key art and its wordmark start below the top bar and fill the safe area"] = function()
		for _, viewport in { { 850, 411, 58 }, { 800, 360, 58 }, { 1280, 720, 58 }, { 1920, 1080, 36 } } do
			local width, height, top = viewport[1], viewport[2], viewport[3]
			local art = Flow.art(width, height, top)
			local label = width .. "x" .. height
			assert(art.y >= top, "art top under the top bar at " .. label)
			assert(art.x <= 0 and art.x + art.width >= width, "art spans the width at " .. label)
			assert(art.y + art.height >= height, "art reaches the bottom at " .. label)
			assert(math.abs(art.width / art.height - Flow.ART_ASPECT) < 0.01, "art keeps its aspect at " .. label)
		end
		local boot = fs.readFile("games/robango-island/src/first/RobangoBoot.client.luau")
		assert(string.find(boot, "local frame = Flow.art(size.X, size.Y, top)", 1, true), "boot places the art")
		assert(string.find(boot, "GuiService.TopbarInset.Max.Y", 1, true), "from the live top bar")
		assert(string.find(boot, "Flow.layout(size.X, size.Y, top)", 1, true), "copy below the same top")
	end,
	-- A short view (title column taller than the space under a 58 px top bar) used to raise
	-- TITLE_UNDER_TOPBAR and kill the boot script; the title now clamps below the inset.
	["short views with a tall top bar keep the title below the inset instead of asserting"] = function()
		for _, view in { { 400, 120, 58 }, { 600, 130, 58 }, { 800, 360, 58 } } do
			local ok, rects = pcall(Flow.layout, view[1], view[2], view[3])
			local label = view[1] .. "x" .. view[2]
			assert(ok, "layout raised at " .. label .. ": " .. tostring(rects))
			assert(rects.title.y >= view[3], "title under the top bar at " .. label)
		end
	end,
	-- ADR-13 (p134 v53): Start reports vitals-wake so the server ends the join hold on hunger. A
	-- refusal (profile still loading) is retried, bounded; nothing is sent while the title is up.
	["Start reports vitals-wake once, retrying a refusal a bounded number of times"] = function()
		local attributes: { [string]: any } = {}
		local watchers: { [string]: { () -> () } } = {}
		local player = {
			GetAttribute = function(_, name: string)
				return attributes[name]
			end,
			SetAttribute = function(_, name: string, value: any)
				attributes[name] = value
				for _, fn in watchers[name] or {} do
					fn()
				end
			end,
			GetAttributeChangedSignal = function(_, name: string)
				return {
					Connect = function(_, fn)
						watchers[name] = watchers[name] or {}
						table.insert(watchers[name], fn)
						return { Disconnect = function() end }
					end,
				}
			end,
		}
		local sent: { string } = {}
		local answers = { { ok = false, reason = "profile not ready" }, { ok = false }, { ok = true } }
		local retries: { () -> () } = {}
		Flow.bindWake(player, function(action: string): any
			table.insert(sent, action)
			return table.remove(answers, 1) or { ok = true }
		end, function(seconds: number, fn: () -> ())
			assert(seconds == Flow.WAKE_RETRY_SECONDS, "retry delay")
			table.insert(retries, fn)
		end)
		assert(#sent == 0, "nothing while the title is up")
		player:SetAttribute("ForgeTitleDone", true)
		while #retries > 0 do
			table.remove(retries, 1)()
		end
		assert(#sent == 3 and sent[1] == Flow.WAKE_ACTION, "retried until accepted, sent " .. #sent)
		player:SetAttribute("ForgeTitleDone", true)
		assert(#sent == 3, "sent once")
		-- A server that never accepts: bounded attempts, then the server's 10-minute cap ends the hold.
		local refusals = 0
		local stuck = {
			GetAttribute = function()
				return true
			end,
			GetAttributeChangedSignal = player.GetAttributeChangedSignal,
		}
		local pending: { () -> () } = {}
		Flow.bindWake(stuck, function(): any
			refusals += 1
			return { ok = false }
		end, function(_, fn)
			table.insert(pending, fn)
		end)
		while #pending > 0 do
			table.remove(pending, 1)()
		end
		assert(refusals == Flow.WAKE_ATTEMPTS, "bounded at " .. refusals)
		-- The live wiring: the HUD client sends it through ForgeAction.
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "Flow.bindWake(player", 1, true), "client binds the wake")
	end,
}
