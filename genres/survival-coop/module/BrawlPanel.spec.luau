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
	["mobile and desktop bounds keep touch controls reachable"] = function()
		for _, viewport in { { 360, 640 }, { 1920, 1080 }, { 640, 360 } } do
			local bounds = Panel.layout(viewport[1], viewport[2])
			assert(bounds.width < viewport[1] and bounds.height < viewport[2], "viewport fit")
			assert(bounds.controlHeight >= 44 and bounds.height >= 200, "touch and scroll space")
		end
	end,
	["Roblox shaped UI mounts scrolls activates and cleans up"] = function()
		local objects = {}
		local disconnected = 0
		local sent = {}
		local function tuple(...: any): any
			return { ... }
		end
		local ui = {
			Instance = {
				new = function(class: string): any
					local object: any = {
						ClassName = class,
						Destroy = function(self: any)
							self.destroyed = true
						end,
					}
					object.Activated = {
						Connect = function(_: any, callback: any): any
							object.activate = callback
							return {
								Disconnect = function()
									disconnected += 1
								end,
							}
						end,
					}
					table.insert(objects, object)
					return object
				end,
			},
			Vector2 = { new = tuple },
			UDim = { new = tuple },
			UDim2 = { new = tuple, fromScale = tuple, fromOffset = tuple },
			Enum = { AutomaticSize = { Y = "Y" }, SortOrder = { LayoutOrder = "LayoutOrder" } },
		}
		local panel = Panel.mount({
			ui = ui,
			actor = "a",
			parent = {},
			width = 360,
			height = 640,
			now = function(): number
				return 0
			end,
			text = function(key: string): string
				return key
			end,
			send = function(action: string): any
				table.insert(sent, action)
				return { ok = true, amount = 0 }
			end,
		})
		local state = Match.new("m", Policy)
		panel.update(state, 0)
		local join, claim, scroll: any = nil, nil, nil
		for _, object in objects do
			if object.Name == "join" then
				join = object
			end
			if object.Name == "claim" then
				claim = object
			end
			if object.ClassName == "ScrollingFrame" then
				scroll = object
			end
		end
		assert(scroll.AutomaticCanvasSize == "Y" and join.Size[4] == 44, "scroll touch")
		join.activate()
		assert(sent[1] == "survival-coop:brawl-queue", "queue action")
		state.phase, state.actors = "finished", { a = { alive = false } }
		panel.update(state, 0)
		claim.activate()
		claim.activate()
		assert(#sent == 2 and sent[2] == "survival-coop:brawl-reward", "one acknowledged claim")
		panel.resize(1920, 1080)
		panel.destroy()
		assert(disconnected == 7 and objects[1].destroyed, "cleanup")
	end,
}
