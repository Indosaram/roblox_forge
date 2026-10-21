--!strict
local Controller = require("../../../../genres/survival-coop/module/BrawlController")
local Extension = require("../../../../genres/survival-coop/module/BrawlExtension")
local Match = require("../../../../core/domain/brawl/Match")
local Session = require("../../../../core/infra/genre/Session")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local serde = require("@lune/serde")
local M = {}
M.operations = {
	brawl_command = function(ctx, step): string?
		local result = ctx.fixture.command(ctx.playerOf(step), step.action, step.token)
		ctx.results[ctx.playerOf(step)] = result
		return if result.ok ~= (step.expect ~= "refused") then tostring(result.reason) else nil
	end,
	brawl_frame = function(ctx, step): string?
		local result = ctx.fixture.frame(step.elapsed, step.damage or {})
		return if result.ok then nil else result.reason
	end,
	brawl_assert = function(ctx, step): string?
		return ctx.fixture.check(step.check)
	end,
}
function M.new(ctx: any): any
	local fs = require("@lune/fs")
	local combat = require("../../../../genres/survival-coop/module/Combat")
	local runtime = require("@lune/luau").load(fs.readFile("games/robango-island/src/server/BrawlRuntime.luau"), {
		environment = {
			game = {
				GetService = function()
					return {
						WaitForChild = function()
							return {
								genres = {
									["survival-coop"] = {
										module = {
											BrawlController = Controller,
											Combat = combat,
											JournalPorts = require(
												"../../../../genres/survival-coop/module/JournalPorts"
											),
										},
									},
								},
								core = { domain = { brawl = { Match = Match } } },
							}
						end,
					}
				end,
			},
			require = function(value)
				return value
			end,
		},
	})()
	local clock = ctx.now()
	local session: any = nil
	local controller: any = nil
	local positions: any = { owner = { x = 0, y = 0, z = 0 }, rival = { x = 0, y = 0, z = 0 } }
	local policy = (Content :: any).brawlPolicy
	local function now(): number
		return clock
	end
	controller = Controller.new({
		store = {
			UpdateAsync = function(_, key, transform)
				local ok, value = ctx.backend.update(key, transform)
				assert(ok, tostring(value))
				return value
			end,
		},
		owner = "brawl-native",
		key = "brawl-native-arena",
		matchId = "brawl-native-match",
		policy = policy,
		leaseSeconds = 120,
		now = now,
		utc = ctx.now,
		publish = function() end,
		ledger = {
			claim = function(actor, state, utc)
				local result: any = nil
				local ok, reason = session.personalTransaction(actor, function(raw)
					result = Match.reward(raw.envelope.genres["survival-coop"].data, state, actor, utc)
					return raw
				end)
				return if ok then result else { ok = false, reason = reason }
			end,
		},
		facts = function()
			return {
				level = 60,
				maxHealth = 100,
				equipment = { durability = 10, items = { ammo = { catalogId = "branch", quantity = 1 } } },
			}
		end,
		action = function(_, token)
			return {
				kind = if token == "shot" then "ranged" elseif token == "mount" then "mount" else "sprint",
				range = if token == "shot" then 40 else 0,
				ammunition = if token == "shot" then "branch" else nil,
				id = "shot",
				target = "rival",
				millis = clock * 1000,
				origin = positions.owner,
				direction = { x = 1, y = 0, z = 0 },
				rule = {
					mode = "ranged",
					windupMillis = 600,
					recoveryMillis = 1000,
					range = 40,
					facingDot = 0.5,
					damageMilli = 18000,
					ammo = 1,
				},
			}
		end,
		apply = function(state, actor, fact, allowed)
			if fact.kind == "ranged" then
				state.actors[actor].combat = state.actors[actor].combat or { attacks = {}, readyAt = 0 }
				return runtime.attack(state.actors[actor], fact)
			end
			return allowed
		end,
		frame = function()
			return { connected = { owner = true, rival = true }, positions = positions, sight = {} }
		end,
	})
	assert(controller.acquire().ok, "brawl native acquire")
	local extension = Extension.factory({ content = Content, world = { brawl = { controller = controller } } })
	local services = {
		now = now,
		roll = function()
			return 0
		end,
		emit = function() end,
		encode = function(value)
			return serde.encode("json", value)
		end,
		survivalExtensions = { extension },
	}
	local durable = require("../../../../games/robango-island/src/shared/GenreDurable")
	session = Session.new(
		{
			packConfig = require("../../../../games/robango-island/src/shared/GenreConfig"),
			contracts = { require("../../../../genres/survival-coop/module/Contract") },
			controls = {},
			durable = durable,
			storeName = "brawl-native-personal",
		} :: any,
		ctx.backend,
		{ sessionId = "brawl-native-personal", lockTimeout = 120, retries = 0, now = ctx.now },
		services,
		durable
	)
	assert(session.join("owner").ok and session.join("rival").ok, "brawl native join")
	local sequence = 0
	local initial: any = {}
	for _, actor in { "owner", "rival" } do
		initial[actor] = session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data.balance
	end
	return {
		command = function(actor, action, token)
			if action == "start" then
				return extension.recover(actor)
			end
			sequence += 1
			return session.command(actor, {
				action = "survival-coop:brawl-" .. action,
				args = if token then { token } else {},
				requestId = tostring(sequence),
				sessionEpoch = session.commandEpoch(actor),
			})
		end,
		frame = function(elapsed, damage)
			clock = controller.snapshot().startsAt + elapsed
			for actor in damage do
				positions[actor] = { x = 1000, y = 0, z = 0 }
			end
			return controller.tick()
		end,
		check = function(check)
			local state = controller.snapshot()
			if check == "ammunition" then
				return if state.actors.owner.equipment.items.ammo == nil
					then nil
					else "snapshot ammunition not consumed"
			end
			if check == "draw" then
				-- A single authoritative boundary frame eliminates both snapshot actors.
				for _ = 1, 5 do
					clock += 1
					assert(controller.tick().ok, "boundary elimination frame")
				end
				state = controller.snapshot()
				return if state.phase == "finished" and state.winner == nil then nil else "not a draw"
			end
			for _, actor in { "owner", "rival" } do
				local saved = session.personalTransfer(actor).profile().data.envelope.genres["survival-coop"].data
				if saved.balance ~= initial[actor] + policy.participationReward then
					return "settlement not exactly once"
				end
				if state.actors[actor].equipment.durability ~= 10 then
					return "original equipment changed"
				end
			end
			return nil
		end,
	}
end
return M
