--!strict
-- Host-only (luau-lsp lune set): the robango-island generated catalog is not mounted by other game packs; marker: require("@lune/task")
local Panel = require("./BrawlPanel")
local Match = require("../../../core/domain/brawl/Match")
local Policy =
	assert(require("../../../games/robango-island/src/shared/SurvivalContent").brawlPolicy, "generated brawl policy")
return {
	["queue results spectator and quota use generated policy"] = function()
		local state = Match.new("m", Policy)
		local model = Panel.model(state, "a", 0, nil)
		assert(model.join and not model.leave and model.maximum == Policy.maximumPlayers, "queue")
		for _, actor in { "a", "b" } do
			assert(Match.join(state, actor, { level = Policy.minimumLevel, maxHealth = 100, equipment = {} }), "join")
		end
		assert(Match.start(state, 0), "start")
		assert(Panel.model(state, "a", 0, nil).remaining == Policy.preparationSeconds, "preparation clock")
		state.phase = "active"
		assert(Match.leave(state, "a"), "desert")
		model = Panel.model(state, "a", 400, nil)
		assert(model.spectator and model.weather == "storm", "spectator weather")
		state.phase = "finished"
		model = Panel.model(state, "a", 600, nil)
		assert(model.result == "draw" and model.claim and not model.leave, "draw result")
		assert(
			model.dailySettlements == Policy.dailySettlements
				and model.participationReward == Policy.participationReward,
			"generated rewards"
		)
		assert(not Panel.model(state, "a", 600, { ok = true, amount = 0 }).claim, "settled quota claim disabled")
	end,
	["empty queue, weather names and results render as labelled rows"] = function()
		local act = { join = function() end, leave = function() end, claim = function() end, combat = function() end }
		local state = Match.new("m", Policy)
		local rows = Panel.rows("ko-kr", Panel.model(state, "a", 0, nil), Policy, act)
		assert(rows[2].text == Panel.text("ko-kr", "brawl_queue_empty", Policy.minimumPlayers), "empty queue state")
		local join = rows[#rows]
		assert(join.onClick == act.join and join.text == "대기열 참가", "join control last")
		for _, actor in { "a", "b" } do
			assert(Match.join(state, actor, { level = Policy.minimumLevel, maxHealth = 100, equipment = {} }), "join")
		end
		assert(Match.start(state, 0), "start")
		state.phase = "active"
		local fog = Policy.weather[3]
		rows = Panel.rows("en-us", Panel.model(state, "a", state.startsAt + fog.at, nil), Policy, act)
		local weather = rows[2]
		assert(weather.icon == "weather." .. fog.id and string.find(weather.text, "Weather: Fog.", 1, true), "fog row")
		assert(string.find(weather.text, tostring(fog.rangeCap) .. " studs", 1, true), "fog effect from policy")
		assert(string.find(rows[3].text, "Next weather: Storm", 1, true), "next weather row")
		local combat = 0
		for _, row in rows do
			combat += if row.onClick == nil then 0 else 1
		end
		assert(combat == 5, "four combat controls plus leave while alive")
		state.phase, state.winner = "finished", "a"
		rows = Panel.rows("ko-kr", Panel.model(state, "a", 600, { ok = true, amount = 150 }), Policy, act)
		assert(rows[1].text == Panel.text("ko-kr", "brawl_result_win"), "win result")
		assert(rows[3].text == Panel.text("ko-kr", "brawl_settled", 150), "settlement shown")
		rows = Panel.rows("en-us", nil, Policy, act)
		assert(rows[1].text == Panel.text("en-us", "brawl_unavailable") and #rows == 4, "unavailable explains rules")
	end,
	["docked kit sheet sends queue and acknowledged claim once"] = function()
		local widgets, sent, docks = {}, {}, {}
		local listener: any = nil
		local frame = { Visible = false, AbsoluteSize = { X = 360, Y = 560 } }
		local function widget(_theme: any, props: any): any
			local made = table.clone(props)
			made.Destroy = function(self: any)
				self.destroyed = true
			end
			table.insert(widgets, made)
			return made
		end
		local images = 0
		local ctx: any = {
			ui = {
				components = {
					modalSheet = function(_theme: any, props: any): any
						assert(props.title == "Brawl", "kit header title")
						return { frame = frame, scroll = {}, close = { Activated = { Connect = function() end } } }
					end,
					label = widget,
					button = widget,
				},
				theme = { default = {} },
			},
			locale = "en-us",
			playerGui = {},
			actorId = "a",
			instance = {
				new = function(class: string): any
					images += if class == "ImageLabel" then 1 else 0
					return { Destroy = function() end }
				end,
			},
			udim = { new = function() end },
			udim2 = {
				new = function(xs: number, xo: number, ys: number, yo: number): any
					return { xs = xs, xo = xo, ys = ys, yo = yo }
				end,
			},
			icons = {
				ui = function(id: string): any
					return { image = "rbxassetid://1", key = "ui.icon." .. id }
				end,
			},
			dock = function(entry: any): any
				docks[entry.id] = entry
				return { open = function() end, setAvailable = function() end }
			end,
			onSnapshot = function(callback: any): any
				listener = callback
				return function() end
			end,
			serverNow = function(): number
				return 0
			end,
			send = function(action: string): any
				table.insert(sent, action)
				return { ok = true, amount = 0 }
			end,
		}
		local panel = Panel.factory(ctx)
		assert(docks.brawl and docks.brawl.order == 65, "brawl dock entry")
		local state = Match.new("m", Policy)
		listener({ brawl = state })
		panel.open()
		local function press(text: string)
			for _, item in widgets do
				if not item.destroyed and item.text == text and item.onClick then
					item.onClick()
					return
				end
			end
			error("no button " .. text)
		end
		for _, item in widgets do
			assert(item.destroyed or item.size.yo >= 48, "rows keep the 48px touch minimum")
		end
		assert(images >= 1, "weather icon mounted")
		press("Join queue")
		assert(sent[1] == "survival-coop:brawl-queue", "queue action")
		state.phase, state.actors, state.order = "finished", { a = { alive = false } }, { "a" }
		listener({ brawl = state })
		press("Claim result")
		local claims = 0
		for _, item in widgets do
			claims += if not item.destroyed and item.text == "Claim result" then 1 else 0
		end
		assert(#sent == 2 and sent[2] == "survival-coop:brawl-reward" and claims == 0, "one acknowledged claim")
		panel.destroy()
	end,
}
