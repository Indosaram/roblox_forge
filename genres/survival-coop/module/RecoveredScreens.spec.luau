--!strict
-- Recovered spec screens (p92): ui.recipe-tracker, ui.score-library, ui.clan-treasury,
-- ui.clan-research, ui.territory, ui.build-manage, ui.social, ui.arrival. Pure models in EN/KO
-- with empty states, sheet geometry at 1280x720 and 360x640 (48 px rows, no clipped text), the
-- real SocialSheet renderer on fake Instances, navigator reachability and command ids.
local fs = require("@lune/fs")
local Screens = require("./RecoveredScreens")
local L = require("./ScreenText")
L.use(require("../../../games/robango-island/PackText.fixture").screenText)
local Sheet = require("./SocialSheet")
local HUDModel = require("./SurvivalHUDModel")
local Navigator = require("./NavigatorPanel")
local Selection = require("./MusicSelection")
local Store = require("./ScoreLibraryStore")
local Clan = require("../../../core/domain/settlement/Clan")
local Topology = require("../../../core/domain/settlement/Multistorey")
local luau = require("@lune/luau")
local Content: any = luau.load(fs.readFile("games/robango-island/src/shared/SurvivalContent.luau"))()

local LOCALES = { "en-us", "ko-kr" }
local VIEWPORTS: { { any } } = { { 1280, 720, false }, { 360, 640, true } }

local function noop() end
local ACT = setmetatable({}, {
	__index = function()
		return noop
	end,
})

local function check(rows: { any }, label: string)
	assert(#rows > 0, label .. ": blank screen")
	for _, row in rows do
		assert(type(row.text) == "string" and row.text ~= "", label .. ": empty row")
		assert(
			not string.find(row.text, "scr%.") and not string.find(row.text, "%%[ds]"),
			label .. ": raw key " .. row.text
		)
		for _, viewport in VIEWPORTS do
			local _, _, w, h = HUDModel.contextSheet(viewport[1], viewport[2], viewport[3])
			local width = Sheet.contentWidth(w)
			local height = Sheet.rowHeight(row.text, width)
			assert(height >= 48, label .. ": touch target under 48")
			assert(height <= h - 56, label .. ": row taller than the sheet " .. row.text)
		end
	end
end

local function clan(): any
	local state = Clan.new("tide", "1")
	state.members["2"] = { role = "member", withdraw = false }
	state.funds, state.level = 2500, 9
	return state
end

local function texts(rows: { any }): string
	local out = {}
	for _, row in rows do
		table.insert(out, row.text)
	end
	return table.concat(out, "\n")
end

local function press(rows: { any }, text: string)
	for _, row in rows do
		if row.text == text and row.onClick then
			row.onClick()
			return
		end
	end
	error("no button " .. text .. " in\n" .. texts(rows))
end

return {
	["every screen string has matching en-us and ko-kr locale rows"] = function()
		-- The copy ships only in strings.csv; every scr.* key the screens name must resolve in both locales.
		local count = 0
		for _, name in { "RecoveredScreens", "NavigatorPanel", "ScreenText" } do
			local source = fs.readFile("genres/survival-coop/module/" .. name .. ".luau")
			for key in string.gmatch(source, '"(scr%.[%w_%.%-]+)"') do
				if string.sub(key, -1) ~= "." and string.sub(key, -1) ~= "_" then -- prefixes built at runtime
					assert(L.has(key), key .. ": missing from strings.csv")
					assert(L.text("en-us", key) ~= "" and L.text("ko-kr", key) ~= "", key .. ": empty locale text")
					count += 1
				end
			end
		end
		assert(count > 100, "screen keys scanned: " .. count)
		assert(L.text("en-us", "scr.no.such.key") == "", "an unknown key never renders its id")
	end,
	["each screen has an empty state that fits both viewports in both languages"] = function()
		for _, locale in LOCALES do
			check(Screens.trackerRows(locale, {}, ACT), "tracker")
			check(Screens.libraryRows(locale, {}, ACT), "library loading")
			check(Screens.libraryRows(locale, { library = {} }, ACT), "library empty")
			check(Screens.treasuryRows(locale, { actorId = "1", amount = 10 }, ACT), "treasury")
			check(Screens.researchRows(locale, { actorId = "1", now = 0 }, ACT), "research")
			check(Screens.territoryRows(locale, { actorId = "1", now = 0 }, ACT), "territory")
			check(Screens.manageRows(locale, { actorId = "1" }, ACT), "manage")
			check(Screens.socialRows(locale, { actorId = "1", capacity = 16, roster = {} }, ACT), "social")
			check(Screens.arrivalRows(locale, {}, ACT), "arrival")
			check(Screens.jobsRows(locale, { now = 0 }, ACT), "jobs")
			check(Screens.rolesRows(locale, { actorId = "1" }, ACT), "roles")
			check(Screens.buyRows(locale, {}, ACT), "buy")
			assert(
				string.find(
					texts(Screens.jobsRows(locale, { now = 0 }, ACT)),
					L.text(locale, "scr.jobs.empty"),
					1,
					true
				),
				"jobs empty copy"
			)
			assert(
				string.find(texts(Screens.buyRows(locale, {}, ACT)), L.text(locale, "scr.buy.empty"), 1, true),
				"buy empty copy"
			)
			assert(
				string.find(texts(Screens.trackerRows(locale, {}, ACT)), L.text(locale, "scr.tracker.empty"), 1, true),
				"tracker empty copy"
			)
			assert(
				string.find(texts(Screens.treasuryRows(locale, {}, ACT)), L.text(locale, "scr.clan.none"), 1, true),
				"no clan copy"
			)
		end
	end,
	["recipe tracker shows bag + storage per input, deficits and untracks"] = function()
		local recipe = Content.recipes[1]
		local input = recipe.inputs[1]
		local bag = {
			items = { a = { catalogId = input.item, quantity = 1 } },
			reservations = {},
		}
		local untracked: string? = nil
		for _, locale in LOCALES do
			local rows = Screens.trackerRows(locale, {
				bag = bag,
				recipes = Content.recipes,
				marks = { favorites = {}, todo = { [recipe.id] = true } },
			}, {
				untrack = function(id: string)
					untracked = id
				end,
				craft = noop,
			})
			check(rows, "tracker " .. locale)
			assert(not string.find(texts(rows), L.text(locale, "scr.tracker.empty"), 1, true), "not empty")
			press(rows, L.text(locale, "scr.tracker.untrack", recipe.id))
			assert(untracked == recipe.id, "untrack sends the recipe")
		end
	end,
	["score library lists saved revisions, selects and links editor/import/share"] = function()
		Selection.set(nil)
		local picked: any = nil
		local entry = { scoreId = "7:score:1", revision = 2, tempo = 120, parts = 2, seconds = 30 }
		for _, locale in LOCALES do
			local rows = Screens.libraryRows(locale, { library = { entry } }, {
				select = function(value: any)
					picked = value
				end,
			})
			check(rows, "library " .. locale)
			press(rows, L.text(locale, "scr.library.row", "7:score:1", 2, 120, 2, 30))
			assert(picked == entry, "row selects the revision")
			local selected = Screens.libraryRows(locale, { library = { entry }, selected = entry }, ACT)
			assert(string.find(texts(selected), L.text(locale, "scr.library.share"), 1, true), "share offered")
		end
	end,
	["score store summaries come from one read and refresh on save"] = function()
		local values: any = {}
		local reads = 0
		local dataStore = {}
		function dataStore:GetAsync(key: string): any
			reads += 1
			return values[key]
		end
		function dataStore:UpdateAsync(key: string, transform: any): any
			values[key] = transform(values[key])
			return values[key]
		end
		local Rules = require("../../../core/domain/music/TestCatalog")
		local store = Store.new({
			dataStoreService = {
				GetDataStore = function()
					return dataStore
				end,
			},
			storeName = "s",
			rules = Rules,
			maxStoreBytes = 4000000,
			encode = function()
				return ""
			end,
		})
		assert(#(store.summaries("7") :: any) == 0 and reads == 1, "empty library after one read")
		store.summaries("7")
		assert(reads == 1, "cached")
		local saved = store.save("7", nil, {
			version = 1,
			tempo = 120,
			parts = {
				{
					instrumentId = "piano",
					notes = { { startTick = 0, durationTicks = 960, pitch = 60, velocity = 90 } },
				},
			},
		}, "r1")
		assert(saved.ok, tostring(saved.reason))
		local rows = store.summaries("7") :: any
		assert(
			#rows == 1 and rows[1].revision == 1 and rows[1].tempo == 120 and rows[1].seconds == 1,
			"summary refreshed"
		)
	end,
	["treasury confirms a deposit before sending and shows the ledger"] = function()
		local state = clan()
		state.walletOperations = {
			["1:1:a"] = { request = { actor = "1", operation = "deposit", amount = 50 }, result = { ok = true } },
		}
		for _, locale in LOCALES do
			local asked: string? = nil
			local rows = Screens.treasuryRows(locale, { clan = state, actorId = "1", amount = 50, balance = 99 }, {
				ask = function(op: string)
					asked = op
				end,
				amount = noop,
			})
			check(rows, "treasury " .. locale)
			assert(string.find(texts(rows), L.text(locale, "scr.treasury.no_withdraw"), 1, true), "withdraw gate")
			press(rows, L.text(locale, "scr.treasury.deposit", 50))
			assert(asked == "deposit", "deposit asks for confirmation first")
			local confirm =
				Screens.treasuryRows(locale, { clan = state, actorId = "1", amount = 50, pending = "deposit" }, ACT)
			assert(
				string.find(texts(confirm), L.text(locale, "scr.treasury.confirm_deposit", 50), 1, true),
				"confirm copy"
			)
			assert(
				string.find(
					texts(rows),
					L.text(locale, "scr.treasury.entry_deposit", 50, "1", L.text(locale, "scr.status.done")),
					1,
					true
				),
				"ledger row"
			)
		end
	end,
	["clan research shows gates, starts, completes and the outpost-bound capture"] = function()
		local state = clan()
		for _, locale in LOCALES do
			local sent: { any } = {}
			local rows = Screens.researchRows(locale, {
				clan = state,
				actorId = "1",
				now = 0,
				operations = Content.operations,
				policy = Content.clanPolicy,
			}, {
				command = function(op: string, args: any)
					table.insert(sent, { op, args })
				end,
			})
			check(rows, "research " .. locale)
			local all = texts(rows)
			assert(string.find(all, L.text(locale, "scr.research.locked_level", 12), 1, true), "combat level gate")
			press(rows, L.text(locale, "scr.research.start", L.text(locale, "scr.research.exploration")))
			assert(sent[1][1] == "research-start" and sent[1][2].id == "clan-research-exploration", "start id")
			assert(string.find(all, L.text(locale, "scr.research.capture_off"), 1, true), "capture needs outpost")
			local member = Screens.researchRows(locale, {
				clan = state,
				actorId = "2",
				now = 0,
				operations = Content.operations,
				policy = Content.clanPolicy,
			}, ACT)
			assert(string.find(texts(member), L.text(locale, "scr.research.locked_role"), 1, true), "member read-only")
			local running = Clan.apply(state, "1", "research-start", { id = "clan-research-exploration" }, "j1", 0, {
				rules = Content.clanPolicy,
				operations = {
					["clan-research-exploration"] = Content.operations[(function()
						for index, op in Content.operations do
							if op.id == "clan-research-exploration" then
								return index
							end
						end
						return 0
					end)()],
				},
				hall = true,
			})
			assert(running, "job started")
			local done: { any } = {}
			local later = Screens.researchRows(locale, {
				clan = running,
				actorId = "1",
				now = 10000,
				operations = Content.operations,
				policy = Content.clanPolicy,
			}, {
				command = function(op: string, args: any)
					table.insert(done, { op, args })
				end,
			})
			press(later, L.text(locale, "scr.research.complete", L.text(locale, "scr.research.exploration")))
			assert(done[1][1] == "research-complete" and done[1][2].jobId == "j1", "complete job id")
		end
	end,
	["territory separates personal and clan boundaries and lists the change journal"] = function()
		local state = clan()
		state.territory = "rw.harbor"
		state.journal = { { operationId = "x", from = "", to = "rw.harbor", at = 100 } }
		for _, locale in LOCALES do
			local asked = false
			local rows = Screens.territoryRows(locale, {
				clan = state,
				home = { owner = "1", location = "cove-east", landRank = 2 },
				outpost = { owner = "tide", expiresAt = 500 },
				actorId = "1",
				now = 160,
				here = "rw.a1.s1",
			}, {
				ask = function()
					asked = true
				end,
			})
			check(rows, "territory " .. locale)
			local all = texts(rows)
			assert(not string.find(all, "rw%."), "no raw layout ids")
			assert(
				string.find(all, L.text(locale, "scr.territory.clan", L.layout(locale, "rw.harbor")), 1, true),
				"clan"
			)
			assert(
				string.find(
					all,
					L.text(
						locale,
						"scr.territory.entry",
						"1:00",
						L.text(locale, "scr.territory.nobody"),
						L.layout(locale, "rw.harbor")
					),
					1,
					true
				),
				"journal"
			)
			press(rows, L.text(locale, "scr.territory.claim", L.layout(locale, "rw.a1.s1")))
			assert(asked, "claim asks for confirmation")
		end
	end,
	["build manage recovers only parts the topology lets go and confirms first"] = function()
		local policy = { floors = 3, cellStuds = 4, floorHeight = 10, baseY = 0, stairSteps = 4 }
		local state = Topology.new()
		state = assert(Topology.place(state, policy, { id = "f1", kind = "floor", x = 0, z = 0, floor = 1 }, 0))
		state = assert(Topology.place(state, policy, { id = "p1", kind = "pillar", x = 0, z = 0, floor = 1 }, 1))
		state = assert(Topology.place(state, policy, { id = "f2", kind = "floor", x = 0, z = 0, floor = 2 }, 2))
		for _, locale in LOCALES do
			local asked: any = nil
			local rows = Screens.manageRows(locale, {
				building = state,
				home = { owner = "1", homeId = "home:1", structures = { s1 = { kind = "workbench" } }, plots = {} },
				actorId = "1",
				names = { workbench = "Workbench" },
			}, {
				ask = function(kind: string, id: string)
					asked = { kind, id }
				end,
				move = noop,
			})
			check(rows, "manage " .. locale)
			local all = texts(rows)
			assert(
				string.find(
					all,
					L.text(
						locale,
						"scr.manage.blocked",
						1,
						L.text(locale, "scr.manage.pillar"),
						L.refusal(locale, "SUPPORT_REQUIRED")
					),
					1,
					true
				),
				"supporting pillar blocked with reason"
			)
			press(rows, L.text(locale, "scr.manage.part", 2, L.text(locale, "scr.manage.floor"), 0, 0))
			assert(asked[1] == "part" and asked[2] == "f2", "top floor recoverable")
			press(rows, L.text(locale, "scr.manage.structure", "Workbench"))
			assert(asked[1] == "structure" and asked[2] == "s1", "structure recover")
		end
	end,
	["players lists the server roster with visit, trade, party and clan invites"] = function()
		local state = clan()
		for _, locale in LOCALES do
			local sent: { any } = {}
			local rows = Screens.socialRows(locale, {
				roster = { { id = "1", name = "Me" }, { id = "3", name = "Ari" } },
				actorId = "1",
				capacity = 16,
				hosts = { ["3"] = true },
				clan = state,
			}, {
				send = function(action: string, args: any)
					table.insert(sent, { action, args })
				end,
			})
			check(rows, "social " .. locale)
			assert(string.find(texts(rows), L.text(locale, "scr.social.count", 2, 16), 1, true), "capacity line")
			press(rows, L.text(locale, "scr.social.visit", "Ari"))
			press(rows, L.text(locale, "scr.social.trade", "Ari"))
			press(rows, L.text(locale, "scr.social.party", "Ari"))
			press(rows, L.text(locale, "scr.social.clan", "Ari"))
			assert(sent[1][1] == "camp-visit-open" and sent[1][2][1] == "3", "visit")
			assert(
				sent[2][1] == "trade-open" and sent[3][1] == "party-action" and sent[3][2][1] == "invite",
				"trade/party"
			)
			assert(sent[4][1] == "clan-invite" and sent[4][2][2].target == "3", "clan invite")
		end
	end,
	["arrival shows the premise, the objective and an optional skip"] = function()
		for _, locale in LOCALES do
			local skipped = false
			local rows = Screens.arrivalRows(locale, { tutorial = { step = "arrive" }, objective = "Gather fiber" }, {
				close = noop,
				skip = function()
					skipped = true
				end,
			})
			check(rows, "arrival " .. locale)
			assert(string.find(texts(rows), L.text(locale, "scr.arrival.together"), 1, true), "premise")
			assert(string.find(texts(rows), L.text(locale, "scr.arrival.goal", "Gather fiber"), 1, true), "objective")
			press(rows, L.text(locale, "scr.arrival.skip"))
			assert(skipped, "skip")
			local done = Screens.arrivalRows(locale, { tutorial = { complete = true } }, ACT)
			assert(
				not string.find(texts(done), L.text(locale, "scr.arrival.skip"), 1, true),
				"no skip after onboarding"
			)
		end
	end,
	["p93 build manage names the starter farm plot"] = function()
		local PackText = require("../../../games/robango-island/PackText.fixture")
		for _, locale in LOCALES do
			local home = { owner = "1", structures = { ["farm-plot"] = { kind = "farm-plot" } } }
			local rows = Screens.manageRows(locale, { home = home, actorId = "1", names = PackText.names(locale) }, ACT)
			check(rows, "manage " .. locale)
			assert(not string.find(texts(rows), "farm-plot", 1, true), "raw structure id: " .. texts(rows))
		end
	end,
	["p93 arrival on a touch device shows no keyboard key"] = function()
		for _, locale in LOCALES do
			local touch =
				Screens.arrivalRows(locale, { tutorial = { step = "gather" }, objective = "E", touch = true }, ACT)
			assert(string.find(texts(touch), L.text(locale, "scr.arrival.goal_touch"), 1, true), "touch goal")
			assert(not string.find(texts(touch), "E", 1, true) or locale == "en-us", "no key hint on touch")
		end
	end,
	["p93 arrival opens itself only on the onboarding server"] = function()
		for _, role in { "onboarding", "brawl", "team-outpost" } do
			local docks: { [string]: any } = {}
			local callbacks: { any } = {}
			local node = function(): any
				return { Activated = { Connect = function() end }, Destroy = noop }
			end
			local widgets = function(): any
				return node()
			end
			Screens.factory({
				locale = "ko-kr",
				actorId = "1",
				worldRole = role,
				content = Content,
				playerGui = {},
				instance = { new = node },
				udim2 = { new = noop },
				ui = {
					theme = { default = {} },
					components = {
						modalSheet = function(): any
							return { frame = node(), scroll = node(), close = node() }
						end,
						label = widgets,
						button = widgets,
					},
				},
				send = function(): any
					return { ok = true }
				end,
				onSnapshot = function(callback: any): () -> ()
					table.insert(callbacks, callback)
					return noop
				end,
				dock = function(entry: any): any
					docks[entry.id] = entry
					return {
						open = function()
							entry.setOpen(true)
						end,
						setAvailable = noop,
					}
				end,
			})
			for _, callback in callbacks do
				callback({ contracts = { tutorial = { step = "arrive" } } }, { roster = {}, snapshots = {} })
			end
			assert(docks.arrival.isOpen() == (role == "onboarding"), role .. ": arrival auto-open")
		end
	end,
	["factory mounts every screen as a hidden navigator entry and sends real commands"] = function()
		local nodes: { any } = {}
		local function node(): any
			local item: any = { Visible = true, AbsoluteSize = { X = 344, Y = 560 } }
			item.Activated = {
				Connect = function(_self: any, callback: any)
					item.fire = callback
					return { Disconnect = noop }
				end,
			}
			function item.Destroy(self: any)
				self.Parent = nil
			end
			table.insert(nodes, item)
			return item
		end
		local docks: { [string]: any } = {}
		local snapshot: { any } = {}
		local sent: { any } = {}
		local widgets = function(_theme: any, props: any): any
			local item = node()
			item.Text, item.Parent, item.Size, item.onClick = props.text, props.parent, props.size, props.onClick
			return item
		end
		local ctx: any = {
			locale = "ko-kr",
			actorId = "1",
			capacity = 16,
			content = Content,
			names = {},
			playerGui = {},
			instance = { new = node },
			udim2 = {
				new = function(...: any): any
					return { ... }
				end,
			},
			ui = {
				theme = { default = {} },
				components = {
					modalSheet = function(): any
						return { frame = node(), scroll = node(), close = node() }
					end,
					label = widgets,
					button = widgets,
				},
			},
			serverNow = function(): number
				return 0
			end,
			worldRole = "onboarding",
			currentLayout = function(): string?
				return "rw.harbor"
			end,
			send = function(action: string, args: any): any
				table.insert(sent, { action, args })
				return { ok = true }
			end,
			onSnapshot = function(callback: any): () -> ()
				table.insert(snapshot, callback)
				return noop
			end,
			dock = function(entry: any): any
				docks[entry.id] = entry
				return {
					open = function()
						entry.setOpen(true)
					end,
					setAvailable = noop,
				}
			end,
			open = function(): boolean
				return true
			end,
		}
		local mounted = Screens.factory(ctx)
		for _, screen in Screens.SCREENS do
			local entry = docks[screen.id]
			assert(entry and entry.hidden == true, screen.id .. ": registered as a hidden navigator entry")
		end
		local navigator = Navigator.model("ko-kr", function(id: string): (boolean, boolean, string?)
			return docks[id] ~= nil, docks[id] ~= nil, nil
		end)
		for _, screen in Screens.SCREENS do
			if screen.contextual then
				continue
			end
			local found = false
			for _, row in navigator do
				found = found or (row.id == screen.id and row.open)
			end
			assert(found, screen.id .. ": reachable from the navigator")
		end
		local state = clan()
		for _, callback in snapshot do
			callback({
				clan = state,
				contracts = { tutorial = { step = "arrive" } },
				ensemble = { library = {} },
			}, { roster = { { id = "1", name = "Me" }, { id = "3", name = "Ari" } }, snapshots = {} })
		end
		assert(docks.arrival.isOpen(), "arrival opens itself during onboarding")
		docks.territory.setOpen(true)
		local claim: any = nil
		for _, item in nodes do
			if item.Text == L.text("ko-kr", "scr.territory.claim", L.layout("ko-kr", "rw.harbor")) and item.onClick then
				claim = item
			end
		end
		assert(claim, "claim button rendered")
		claim.onClick()
		for _, item in nodes do
			if item.Parent ~= nil and item.Text == L.text("ko-kr", "scr.confirm") and item.onClick then
				item.onClick()
				break
			end
		end
		assert(sent[#sent][1] == "survival-coop:clan-relocate", "relocate sent")
		assert(sent[#sent][2][2].territory == "rw.harbor" and sent[#sent][2][2].expectedRevision == 0, "bound args")
		for _, item in nodes do
			-- Rows carry text; the sheet's scroller (sized against its pinned footer) is not a row.
			if item.Size and item.Parent ~= nil and item.Text then
				assert(item.Size[4] >= 48, "rendered rows are 48 px targets")
			end
		end
		-- ui.market-buy: the listing handed over by the market's Buy confirms with its exact id and price.
		Screens.buying.listing = { id = "L1", catalogId = "wood", quantity = 3, price = 40 }
		for _, callback in snapshot do
			callback({ market = { balance = 100, listings = { { id = "L1", price = 40 } } } }, { snapshots = {} })
		end
		docks["market-buy"].setOpen(true)
		local buy: any = nil
		for _, item in nodes do
			if item.Parent ~= nil and item.Text == L.text("ko-kr", "scr.buy.confirm", 40) and item.onClick then
				buy = item
			end
		end
		assert(buy, "buy confirm rendered")
		buy.onClick()
		assert(sent[#sent][1] == "survival-coop:market-buy", "market-buy sent")
		assert(sent[#sent][2][1] == "L1" and sent[#sent][2][2] == 40, "exact listing and price")
		Screens.buying.listing = nil
		mounted.destroy()
		local market = fs.readFile("genres/survival-coop/module/CrossServerMarketPanel.luau")
		assert(string.find(market, 'ctx.open("market-buy")', 1, true), "market Buy opens the confirm screen")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "module.RecoveredScreens).factory", 1, true), "client registers the screens")
	end,
	["craft jobs show escrow, timer and only legal verbs"] = function()
		local function job(state: string, finishAt: number?): any
			return {
				recipeId = "stone-axe",
				state = state,
				finishAt = finishAt,
				inputs = { { catalogId = "stone", quantity = 2 } },
				outputs = { { catalogId = "stone-axe", quantity = 1 } },
			}
		end
		for _, locale in LOCALES do
			local sent: { any } = {}
			local act = setmetatable({
				command = function(action: string, id: string)
					table.insert(sent, { action, id })
				end,
			}, { __index = ACT })
			local names = { ["stone-axe"] = "Axe", stone = "Stone" }
			local reserved = Screens.jobsRows(
				locale,
				{ now = 0, names = names, jobs = { { id = "j1", job = job("Reserved") } } },
				act
			)
			check(reserved, "jobs reserved " .. locale)
			assert(string.find(texts(reserved), L.text(locale, "scr.jobs.escrow", "Stone x2"), 1, true), "escrow line")
			press(reserved, L.text(locale, "scr.jobs.cancel", "Axe"))
			press(reserved, L.text(locale, "scr.jobs.start", "Axe"))
			assert(sent[1][1] == "craft-cancel" and sent[2][1] == "craft-start" and sent[2][2] == "j1", "verbs")
			local running = Screens.jobsRows(
				locale,
				{ now = 0, names = names, jobs = { { id = "j1", job = job("Running", 65000) } } },
				act
			)
			local copy = texts(running)
			assert(string.find(copy, L.text(locale, "scr.jobs.running", "1:05"), 1, true), "countdown")
			assert(
				not string.find(copy, L.text(locale, "scr.jobs.cancel", "Axe"), 1, true),
				"running jobs cannot cancel"
			)
			local done = Screens.jobsRows(
				locale,
				{ now = 70000, names = names, jobs = { { id = "j1", job = job("Running", 65000) } } },
				act
			)
			press(done, L.text(locale, "scr.jobs.complete", "Axe"))
			assert(sent[#sent][1] == "craft-complete", "collect once finished")
		end
	end,
	["craft jobs count down on the open sheet and offer Collect at the deadline (p105 D2)"] = function()
		local job = {
			recipeId = "stone-axe",
			state = "Running",
			startedAt = 1000,
			finishAt = 4000,
			inputs = { { catalogId = "stone", quantity = 2 } },
			outputs = { { catalogId = "stone-axe", quantity = 1 } },
		}
		local function rows(now: number): string
			return texts(Screens.jobsRows("en-us", { now = now, jobs = { { id = "j1", job = job } } }, ACT))
		end
		assert(string.find(rows(3500), L.text("en-us", "scr.jobs.running", "0:01"), 1, true), "half a second left")
		assert(string.find(rows(-60000), L.text("en-us", "scr.jobs.running", "0:03"), 1, true), "capped at the recipe")
		local nodes: { any } = {}
		local function node(): any
			local item: any = { Visible = true, AbsoluteSize = { X = 344, Y = 560 } }
			item.Activated = {
				Connect = function(_self: any, callback: any)
					item.fire = callback
					return { Disconnect = noop }
				end,
			}
			function item.Destroy(self: any)
				self.Parent = nil
			end
			table.insert(nodes, item)
			return item
		end
		local widgets = function(_theme: any, props: any): any
			local item = node()
			item.Text, item.Parent, item.onClick = props.text, props.parent, props.onClick
			return item
		end
		local now, timers, callbacks, docks = 1.5, {} :: { any }, {} :: { any }, {} :: { [string]: any }
		local mounted: any = Screens.factory({
			locale = "en-us",
			actorId = "1",
			names = {},
			playerGui = {},
			instance = { new = node },
			udim2 = {
				new = function(...: any): any
					return { ... }
				end,
			},
			ui = {
				theme = { default = {} },
				components = {
					modalSheet = function(): any
						return { frame = node(), scroll = node(), close = node() }
					end,
					label = widgets,
					button = widgets,
				},
			},
			serverNow = function(): number
				return now
			end,
			delay = function(seconds: number, callback: () -> ())
				table.insert(timers, { seconds = seconds, callback = callback })
			end,
			worldRole = "home",
			send = function(): any
				return { ok = true }
			end,
			onSnapshot = function(callback: any): () -> ()
				table.insert(callbacks, callback)
				return noop
			end,
			dock = function(entry: any): any
				docks[entry.id] = entry
				return {
					open = function()
						entry.setOpen(true)
					end,
					setAvailable = noop,
				}
			end,
		})
		local workshop = { actorId = "1", entries = { j1 = { job = job } } }
		for _, callback in callbacks do
			callback({}, { snapshots = { ["survival-coop"] = { workshop = workshop } } })
		end
		docks.jobs.setOpen(true)
		local function shown(text: string): boolean
			for _, item in nodes do
				if item.Parent ~= nil and item.Text == text then
					return true
				end
			end
			return false
		end
		assert(
			shown(L.text("en-us", "scr.jobs.row", "stone-axe", "j1", L.text("en-us", "scr.jobs.running", "0:03"))),
			"start"
		)
		assert(#timers == 1 and timers[1].seconds == 1, "one tick while running")
		now = 4.2
		assert(table.remove(timers, 1)).callback()
		assert(shown(L.text("en-us", "scr.jobs.complete", "stone-axe")), "Collect without a new snapshot")
		mounted.destroy()
	end,
	["clan roles: the leader assigns roles and withdraw, others read only"] = function()
		local state = clan()
		for _, locale in LOCALES do
			local sent: { any } = {}
			local act = setmetatable({
				command = function(op: string, args: any)
					table.insert(sent, { op, args })
				end,
			}, { __index = ACT })
			local rows = Screens.rolesRows(locale, { clan = state, actorId = "1", names = { ["2"] = "Ari" } }, act)
			check(rows, "roles owner " .. locale)
			assert(
				string.find(
					texts(rows),
					L.text(
						locale,
						"scr.roles.line",
						"Ari",
						L.text(locale, "scr.roles.role_member"),
						L.text(locale, "scr.roles.off")
					),
					1,
					true
				),
				"member line"
			)
			press(rows, L.text(locale, "scr.roles.make_officer", "Ari"))
			press(rows, L.text(locale, "scr.roles.grant", "Ari"))
			assert(sent[1][1] == "role" and sent[1][2].target == "2" and sent[1][2].role == "officer", "role args")
			assert(sent[2][1] == "capability" and sent[2][2].enabled == true, "withdraw grant")
			local member = Screens.rolesRows(locale, { clan = state, actorId = "2" }, act)
			check(member, "roles member " .. locale)
			local previews = {}
			for _, role in { "officer", "member", "visitor" } do
				previews[L.text(locale, "scr.roles.preview", L.text(locale, "scr.roles.role_" .. role))] = true
			end
			for _, row in member do
				-- p111: role previews are read-only and open to every member.
				assert(
					not row.onClick or row.text == L.text(locale, "scr.clan.open") or previews[row.text],
					"members get no role buttons"
				)
			end
		end
	end,
	["p111 clan roles: preview, membership drafts and the leader's confirm or cancel"] = function()
		for _, locale in LOCALES do
			local sent: { any } = {}
			local act = setmetatable({
				command = function(op: string, args: any)
					table.insert(sent, { op, args })
				end,
				preview = function(role: string)
					table.insert(sent, { "preview", role })
				end,
				apply = function(role: string)
					table.insert(sent, { "apply", role })
				end,
				withdraw = function(id: string)
					table.insert(sent, { "withdraw", id })
				end,
			}, { __index = ACT })
			-- Outside a clan: apply as member or visitor, withdraw a pending application.
			local outside = Screens.rolesRows(locale, { actorId = "9", applied = "tide" }, act)
			check(outside, "roles applicant " .. locale)
			press(outside, L.text(locale, "scr.roles.apply_member"))
			press(outside, L.text(locale, "scr.roles.apply_visitor"))
			press(outside, L.text(locale, "scr.roles.withdraw_draft", "tide"))
			assert(sent[1][2] == "member" and sent[2][2] == "visitor" and sent[3][2] == "tide", "applicant buttons")
			local fresh = Screens.rolesRows(locale, { actorId = "9" }, act)
			assert(
				not string.find(texts(fresh), L.text(locale, "scr.roles.withdraw_draft", "tide"), 1, true),
				"no withdraw"
			)
			-- Leader: previews, empty drafts state, then one pending draft to accept or decline.
			local state = clan()
			local empty = Screens.rolesRows(locale, { clan = state, actorId = "1" }, act)
			check(empty, "roles no drafts " .. locale)
			assert(string.find(texts(empty), L.text(locale, "scr.roles.drafts_empty"), 1, true), "drafts empty state")
			press(empty, L.text(locale, "scr.roles.preview", L.text(locale, "scr.roles.role_officer")))
			assert(sent[4][1] == "preview" and sent[4][2] == "officer", "preview role")
			state.drafts = { ["7"] = { role = "visitor", at = 0 } }
			local rows = Screens.rolesRows(locale, { clan = state, actorId = "1", names = { ["7"] = "Bo" } }, act)
			check(rows, "roles drafts " .. locale)
			press(rows, L.text(locale, "scr.roles.draft_confirm", "Bo", L.text(locale, "scr.roles.role_visitor")))
			press(rows, L.text(locale, "scr.roles.draft_cancel", "Bo"))
			assert(sent[5][1] == "draft-confirm" and sent[5][2].target == "7", "confirm args")
			assert(sent[6][1] == "draft-cancel" and sent[6][2].target == "7", "cancel args")
			-- A plain member sees previews but cannot settle drafts.
			local member = Screens.rolesRows(locale, { clan = state, actorId = "2", names = { ["7"] = "Bo" } }, act)
			assert(not string.find(texts(member), L.text(locale, "scr.roles.draft_cancel", "Bo"), 1, true), "member")
			local line = Screens.previewLine(locale, { role = "officer", grants = Clan.preview(state, "officer") })
			check({ { text = line } }, "preview line " .. locale)
			assert(string.find(line, L.text(locale, "scr.roles.cap_invite"), 1, true), line)
			assert(not string.find(line, L.text(locale, "scr.roles.cap_govern"), 1, true), "officer does not govern")
			for _, code in
				{ "ALREADY_MEMBER", "INVALID_ROLE", "DRAFT_EXISTS", "NO_DRAFT", "CLAN_FULL", "WRONG_IDENTITY" }
			do
				local text = L.refusal(locale, code)
				assert(text ~= L.text(locale, "scr.refuse.unknown"), code .. " has its own line")
				check({ { text = text } }, code)
			end
		end
	end,
	["p111 clan roles factory sends clan-preview, clan-draft and draft-confirm with the exact args"] = function()
		local node = function(): any
			local item: any = { Visible = true, AbsoluteSize = { X = 344, Y = 560 } }
			item.Activated = { Connect = function() end }
			item.Destroy = noop
			return item
		end
		local docks: { [string]: any } = {}
		local callbacks: { any } = {}
		local shown: { any } = {}
		local sent: { any } = {}
		local widgets = function(_theme: any, props: any): any
			local item = node()
			item.Text, item.onClick = props.text, props.onClick
			table.insert(shown, item)
			return item
		end
		local reply: any = { ok = true }
		local function screen(): string
			local out = {}
			for _, item in shown do
				table.insert(out, item.Text)
			end
			return table.concat(out, "\n")
		end
		Screens.factory({
			locale = "en-us",
			actorId = "1",
			content = Content,
			names = {},
			playerGui = {},
			instance = { new = node },
			udim2 = { new = noop },
			ui = {
				theme = { default = {} },
				components = {
					modalSheet = function(): any
						return { frame = node(), scroll = node(), close = node() }
					end,
					label = widgets,
					button = widgets,
				},
			},
			serverNow = function(): number
				return 0
			end,
			worldRole = "home",
			askText = function(): string
				return "tide"
			end,
			send = function(action: string, args: any): any
				table.insert(sent, { action, args })
				return reply
			end,
			onSnapshot = function(callback: any): () -> ()
				table.insert(callbacks, callback)
				return noop
			end,
			dock = function(entry: any): any
				docks[entry.id] = entry
				return { open = noop, setAvailable = noop }
			end,
		})
		local function click(text: string)
			for index = #shown, 1, -1 do
				if shown[index].Text == text and shown[index].onClick then
					return shown[index].onClick()
				end
			end
			error("no button " .. text)
		end
		for _, callback in callbacks do
			callback({}, { roster = {}, snapshots = {} })
		end
		docks["clan-roles"].setOpen(true)
		click(L.text("en-us", "scr.roles.apply_visitor"))
		assert(sent[1][1] == "survival-coop:clan-draft", "draft sent")
		assert(sent[1][2][1] == "tide" and sent[1][2][2].role == "visitor", "draft args")
		click(L.text("en-us", "scr.roles.withdraw_draft", "tide"))
		assert(sent[2][1] == "survival-coop:clan-draft-cancel" and sent[2][2][1] == "tide", "withdraw args")
		docks["clan-roles"].setOpen(true)
		-- p115 D4: a refusal from the no-clan view (unknown clan id) must not survive joining a clan.
		reply = { ok = false, reason = "WRONG_IDENTITY" }
		click(L.text("en-us", "scr.roles.apply_member"))
		assert(string.find(screen(), L.refusal("en-us", "WRONG_IDENTITY"), 1, true), "apply refusal shown")
		reply = { ok = true }
		local mark = #shown
		local state = clan()
		state.drafts = { ["7"] = { role = "member", at = 0 } }
		for _, callback in callbacks do
			callback({ clan = state }, { roster = { { id = "7", name = "Bo" } }, snapshots = {} })
		end
		docks["clan-roles"].setOpen(true)
		local after = {}
		for index = mark + 1, #shown do
			table.insert(after, shown[index].Text)
		end
		assert(#after > 0, "member view rendered")
		local member = table.concat(after, "\n")
		assert(not string.find(member, L.refusal("en-us", "WRONG_IDENTITY"), 1, true), "stale refusal cleared")
		reply = { ok = true, data = { role = "member", grants = Clan.preview(state, "member") } }
		click(L.text("en-us", "scr.roles.preview", L.text("en-us", "scr.roles.role_member")))
		assert(sent[4][1] == "survival-coop:clan-preview" and sent[4][2][2].role == "member", "preview args")
		local line = Screens.previewLine("en-us", reply.data)
		assert(string.find(screen(), line, 1, true), "preview shown")
		reply = { ok = false, reason = "CLAN_FULL" }
		click(L.text("en-us", "scr.roles.draft_confirm", "Bo", L.text("en-us", "scr.roles.role_member")))
		assert(sent[5][1] == "survival-coop:clan-draft-confirm", "confirm sent")
		assert(sent[5][2][1] == "tide" and sent[5][2][2].target == "7" and sent[5][2][2].expectedRevision == 0, "args")
		assert(string.find(screen(), L.refusal("en-us", "CLAN_FULL"), 1, true), "localized refusal shown")
	end,
	["p117 clan browse lists name, members and recruiting, pages, and a row fills apply or join"] = function()
		for _, locale in LOCALES do
			local sent: { any } = {}
			local act = setmetatable({
				all = function()
					table.insert(sent, { "all" })
				end,
				page = function(index: number)
					table.insert(sent, { "page", index } :: { any })
				end,
				select = function(id: string)
					table.insert(sent, { "select", id })
				end,
				apply = function(id: string, role: string)
					table.insert(sent, { "apply", id, role })
				end,
				join = function(id: string)
					table.insert(sent, { "join", id })
				end,
				browse = function()
					table.insert(sent, { "browse" })
				end,
			}, { __index = ACT })
			local fresh = Screens.browseRows(locale, {}, act)
			check(fresh, "browse fresh " .. locale)
			press(fresh, L.text(locale, "scr.browse.list"))
			local empty = Screens.browseRows(locale, { page = { query = "zz", page = 1, pages = 1, rows = {} } }, act)
			check(empty, "browse empty " .. locale)
			assert(string.find(texts(empty), L.text(locale, "scr.browse.empty"), 1, true), "empty state")
			local page = {
				query = "",
				page = 2,
				pages = 3,
				rows = {
					{ id = "tide", members = 3, capacity = 50, recruiting = true },
					{ id = "reef", members = 50, capacity = 50, recruiting = false },
				},
			}
			local rows = Screens.browseRows(locale, { page = page, selected = "tide" }, act)
			check(rows, "browse page " .. locale)
			local open = L.text(locale, "scr.browse.row", "tide", 3, 50, L.text(locale, "scr.browse.recruiting"))
			local full = L.text(locale, "scr.browse.row", "reef", 50, 50, L.text(locale, "scr.browse.full"))
			assert(string.find(texts(rows), full, 1, true), "full clan shown as full")
			press(rows, open)
			press(rows, L.text(locale, "scr.browse.prev"))
			press(rows, L.text(locale, "scr.browse.next"))
			press(rows, L.text(locale, "scr.browse.apply_member", "tide"))
			press(rows, L.text(locale, "scr.browse.join", "tide"))
			assert(sent[1][1] == "all" and sent[2][2] == "tide" and sent[3][2] == 1 and sent[4][2] == 3, "nav")
			assert(sent[5][2] == "tide" and sent[5][3] == "member" and sent[6][2] == "tide", "row fills the action")
			local member = Screens.browseRows(locale, { page = page, selected = "tide", inClan = true }, act)
			assert(not string.find(texts(member), L.text(locale, "scr.browse.join", "tide"), 1, true), "in a clan")
			press(Screens.rolesRows(locale, { actorId = "9" }, act), L.text(locale, "scr.roles.browse"))
			assert(sent[7][1] == "browse", "clan roles reaches the browse list")
		end
	end,
	["p117 clan browse factory pages through clan-browse and a picked row sends clan-draft and clan-join"] = function()
		local node = function(): any
			local item: any = { Visible = true, AbsoluteSize = { X = 344, Y = 560 } }
			item.Activated = { Connect = function() end }
			item.Destroy = noop
			return item
		end
		local docks: { [string]: any } = {}
		local callbacks: { any } = {}
		local shown: { any } = {}
		local sent: { any } = {}
		local opened: { string } = {}
		local widgets = function(_theme: any, props: any): any
			local item = node()
			item.Text, item.onClick = props.text, props.onClick
			table.insert(shown, item)
			return item
		end
		Screens.factory({
			locale = "en-us",
			actorId = "9",
			content = Content,
			names = {},
			playerGui = {},
			instance = { new = node },
			udim2 = { new = noop },
			ui = {
				theme = { default = {} },
				components = {
					modalSheet = function(): any
						return { frame = node(), scroll = node(), close = node() }
					end,
					label = widgets,
					button = widgets,
				},
			},
			serverNow = function(): number
				return 0
			end,
			worldRole = "home",
			askText = function(): string
				return "ti"
			end,
			open = function(id: string)
				table.insert(opened, id)
			end,
			send = function(action: string, args: any): any
				table.insert(sent, { action, args })
				return { ok = true }
			end,
			onSnapshot = function(callback: any): () -> ()
				table.insert(callbacks, callback)
				return noop
			end,
			dock = function(entry: any): any
				docks[entry.id] = entry
				return { open = noop, setAvailable = noop }
			end,
		})
		local function click(text: string)
			for index = #shown, 1, -1 do
				if shown[index].Text == text and shown[index].onClick then
					return shown[index].onClick()
				end
			end
			error("no button " .. text)
		end
		for _, callback in callbacks do
			callback({}, { roster = {}, snapshots = {} })
		end
		docks["clan-roles"].setOpen(true)
		click(L.text("en-us", "scr.roles.browse"))
		assert(opened[1] == "clan-browse", "roles opens the browse list")
		assert(docks["clan-browse"].hidden, "browse is a hidden contextual entry")
		docks["clan-browse"].setOpen(true)
		click(L.text("en-us", "scr.browse.search"))
		assert(sent[1][1] == "survival-coop:clan-browse" and sent[1][2][1] == "ti" and sent[1][2][2] == 1, "search")
		local page = {
			query = "ti",
			page = 1,
			pages = 2,
			rows = { { id = "tide", members = 3, capacity = 50, recruiting = true } },
		}
		for _, callback in callbacks do
			callback({ ["clan-browse"] = page }, { roster = {}, snapshots = {} })
		end
		click(L.text("en-us", "scr.browse.next"))
		assert(sent[2][1] == "survival-coop:clan-browse" and sent[2][2][1] == "ti" and sent[2][2][2] == 2, "paging")
		click(L.text("en-us", "scr.browse.row", "tide", 3, 50, L.text("en-us", "scr.browse.recruiting")))
		click(L.text("en-us", "scr.browse.apply_visitor", "tide"))
		assert(sent[3][1] == "survival-coop:clan-draft" and sent[3][2][1] == "tide", "draft from the row")
		assert(sent[3][2][2].role == "visitor", "role")
		click(L.text("en-us", "scr.browse.join", "tide"))
		assert(sent[4][1] == "survival-coop:clan-join" and sent[4][2][1] == "tide", "join from the row")
		docks["clan-roles"].setOpen(true)
		click(L.text("en-us", "scr.roles.withdraw_draft", "tide"))
		assert(sent[5][1] == "survival-coop:clan-draft-cancel", "the browse application shows on clan roles")
	end,
	["market buy confirms the exact bundle and refuses short balance or a gone listing"] = function()
		local listing = { id = "L1", catalogId = "wood", quantity = 3, price = 40 }
		for _, locale in LOCALES do
			local market = { balance = 100, listings = { { id = "L1", price = 40 } } }
			local rows = Screens.buyRows(locale, { listing = listing, market = market, names = { wood = "Wood" } }, ACT)
			check(rows, "buy " .. locale)
			assert(string.find(texts(rows), L.text(locale, "scr.buy.item", "Wood", 3), 1, true), "bundle line")
			press(rows, L.text(locale, "scr.buy.confirm", 40))
			local poor = texts(
				Screens.buyRows(
					locale,
					{ listing = listing, market = { balance = 10, listings = market.listings } },
					ACT
				)
			)
			assert(not string.find(poor, L.text(locale, "scr.buy.confirm", 40), 1, true), "no buy without balance")
			local gone =
				texts(Screens.buyRows(locale, { listing = listing, market = { balance = 100, listings = {} } }, ACT))
			assert(string.find(gone, L.text(locale, "scr.buy.gone"), 1, true), "gone listing")
		end
	end,
	["HUD skill reset opens the ui.skill-reset quote instead of resetting at once"] = function()
		local hud = fs.readFile("genres/survival-coop/module/SurvivalHUD.luau")
		assert(string.find(hud, 'options.openPanel("skill-reset")', 1, true), "HUD routes reset through the quote")
		local sheet = fs.readFile("genres/survival-coop/module/CharacterSheet.luau")
		assert(string.find(sheet, "function M.open(id: string): boolean", 1, true), "character sheets open by id")
		local client = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		assert(string.find(client, "module.CharacterSheet).open", 1, true), "client passes the opener")
	end,
	-- D2c R03: at 800x360 the arrival card's Continue sat under the scroller fold (the five rows plus
	-- padding outgrow the sheet). Continue and Skip are pinned in a footer under the scroller, so
	-- they are on screen at any sheet height; the copy rows scroll above them.
	["arrival Continue and Skip stay on screen at 800x360 and 1280x720"] = function()
		local Panels = require("./ExtensionPanels")
		for _, locale in LOCALES do
			local rows = Screens.arrivalRows(locale, { tutorial = { step = "arrive" }, objective = "E" }, ACT)
			local continue, skip
			for _, row in rows do
				if row.text == L.text(locale, "scr.arrival.continue") then
					continue = row
				elseif row.text == L.text(locale, "scr.arrival.skip") then
					skip = row
				end
			end
			assert(continue and continue.pin and skip and skip.pin, locale .. ": Continue and Skip are pinned")
			local screens: { { width: number, height: number, touch: boolean } } = {
				{ width = 800, height = 360, touch = true },
				{ width = 1280, height = 720, touch = false },
			}
			for _, screen in screens do
				local _, y, w, h = Panels.shellSheet(screen.width, screen.height, screen.touch)
				local tag = locale .. " " .. screen.width .. "x" .. screen.height
				local footer = Sheet.footerHeight(rows)
				-- The footer's buttons end inside the sheet, and the sheet inside the screen.
				assert(footer >= Sheet.MIN_ROW, tag .. ": a footer strip for the pinned rows")
				assert(Sheet.HEADER + footer <= h, tag .. ": header and footer fit the sheet")
				assert(y >= 0 and y + h <= screen.height, tag .. ": sheet inside the screen")
				-- p134 v74 #11: the copy rows fit the scroller above the pinned footer (the 4th line used to
				-- sit under Continue on the landscape phone).
				local scrolled = 2 * 8
				for _, row in rows do
					if not row.pin then
						scrolled += Sheet.rowHeight(row.text, Sheet.contentWidth(w)) + 6
					end
				end
				assert(scrolled - 6 <= h - Sheet.HEADER - footer, tag .. ": the copy fits above the footer")
			end
		end
	end,
	["the shared sheet draws pinned rows in a footer and shortens the scroller"] = function()
		local nodes: { any } = {}
		local function node(): any
			local item: any = { Visible = true, AbsoluteSize = { X = 640, Y = 344 } }
			item.Activated = { Connect = function() end }
			function item.Destroy(self: any)
				self.Parent = nil
			end
			table.insert(nodes, item)
			return item
		end
		local widgets = function(_theme: any, props: any): any
			local item = node()
			item.Text, item.Parent, item.Size = props.text, props.parent, props.size
			return item
		end
		local frame, scroll = node(), node()
		local panel = Sheet.mount({
			playerGui = {},
			instance = { new = node },
			udim2 = {
				new = function(...: any): any
					return { ... }
				end,
			},
			ui = {
				theme = { default = {} },
				components = {
					modalSheet = function(): any
						return { frame = frame, scroll = scroll, close = node() }
					end,
					label = widgets,
					button = widgets,
				},
			},
			onSnapshot = function(): () -> ()
				return noop
			end,
		}, {
			name = "Pin",
			title = "t",
			select = noop,
			rows = function(): { any }
				return {
					{ text = "copy one" },
					{ text = "copy two" },
					{ text = "Continue", onClick = noop, pin = true },
					{ text = "Skip", onClick = noop, pin = true },
				}
			end,
		})
		panel.open()
		local footer
		for _, item in nodes do
			if item.Name == "Footer" then
				footer = item
			end
		end
		assert(footer and footer.Parent == frame and footer.Visible, "footer strip on the sheet frame")
		local inFooter, inScroll = {}, {}
		for _, item in nodes do
			if item.Text and item.Parent == footer then
				table.insert(inFooter, item.Text)
			elseif item.Text and item.Parent == scroll then
				table.insert(inScroll, item.Text)
			end
		end
		assert(
			table.concat(inFooter, ",") == "Continue,Skip",
			"pinned rows in the footer: " .. table.concat(inFooter, ",")
		)
		assert(table.concat(inScroll, ",") == "copy one,copy two", "copy rows scroll")
		local size = scroll.Size
		assert(
			size and size[4] == -(Sheet.HEADER + Sheet.footerHeight({ { text = "x", pin = true } })),
			"scroller ends above the footer"
		)
	end,
}
