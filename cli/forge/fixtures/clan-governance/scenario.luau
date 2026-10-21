--!strict
local ClanExtension = require("../../../../genres/survival-coop/module/ClanExtension")
local OutpostExtension = require("../../../../genres/survival-coop/module/OutpostExtension")
local Clan = require("../../../../core/domain/settlement/Clan")
local Session = require("../../../../core/infra/genre/Session")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Runtime = require("../../../../genres/survival-coop/module/Contract")
local AdapterFixture = require("../../../../genres/survival-coop/module/Adapter.fixture")
local Content = require("../../../../games/robango-island/src/shared/SurvivalContent")
local M = {}
M.operations = {
	clan_command = function(ctx: any, step: any): string?
		local result = ctx.fixture.command(ctx.playerOf(step), "clan", step.action, step.args or {}, step.request)
		ctx.results[ctx.playerOf(step)] = result
		return if result.ok == (step.expect == "refused")
			then "unexpected clan result: " .. tostring(result.reason)
			else nil
	end,
	clan_reconnect = function(ctx: any, _step: any): string?
		return ctx.fixture.reconnect()
	end,
	clan_check = function(ctx: any, step: any): string?
		local state = ctx.fixture.snapshot().clan
		if step.check == "relocated" then
			return if state.territory == "north"
					and state.members.helper.withdraw
					and #state.journal == 1
				then nil
				else "relocation lost permissions"
		elseif step.check == "departed" then
			return if state.members.helper == nil and state.funds == 0 then nil else "departed actor changed funds"
		end
		return "unknown clan assertion"
	end,
}

-- Uses a real Session with the pending action descriptors installed on a cloned
-- contract. The integration lane installs the SAME descriptors on the shared contract.
function M.new(ctx: any): any
	local now = ctx.now()
	local generation, request = 0, 0
	local session: any = nil
	local clan: any = nil
	local outpost: any = nil
	local joined: any = {}
	local operations = {}
	for _, operation in assert(Content.operations, "clan catalog operations required") do
		operations[operation.id] = operation
	end
	local rules = { maxMembers = 50, maxLevel = 20, missionExperience = 100, levelExperience = 500, cancelRefund = 0.5 }
	local siege = { minTeam = 3, maxTeam = 8, matchSeconds = 600, captureSeconds = 180, ownershipSeconds = 86400 }
	local occupants: any = {}
	local teams = {
		{ clanId = "alpha", actors = { "owner", "helper", "third" } },
		{ clanId = "beta", actors = { "enemy", "enemy2", "enemy3" } },
	}
	local function create()
		generation += 1
		local function store(): any
			return Fenced.new(ctx.backend, {
				sessionId = "clan-fixture-" .. tostring(generation),
				leaseSeconds = 86400,
				now = function(): number
					return now
				end,
			})
		end
		clan = ClanExtension.new({
			store = store,
			now = function(): number
				return now
			end,
			owner = function(): string
				return "owner"
			end,
			identity = function(_actor: string, id: string?): string?
				return if id == nil or id == "alpha" then "alpha" else nil
			end,
			visible = function(state: any, actor: string): boolean
				return Clan.allowed(state, actor, "view")
			end,
			facts = function(_actor: string, _id: string, _op: string, _args: any, origin: string): any
				return {
					rules = rules,
					operations = operations,
					hall = true,
					territoryAllowed = true,
					transferAuthorized = false,
					server = origin == "server",
				}
			end,
		})
		outpost = OutpostExtension.new({
			store = store,
			now = function(): number
				return now
			end,
			owner = function(): string
				return ""
			end,
			identity = function(_actor: string, id: string?): string?
				return if id == nil or id == "central" then "central" else nil
			end,
			facts = function(_actor: string, _id: string, _op: string, _args: any, origin: string): any
				return {
					server = origin == "server",
					role = "team-outpost",
					rules = siege,
					teams = teams,
					occupants = occupants,
					eligible = function(actor: string, clanId: string): boolean
						for _, team in teams do
							if team.clanId == clanId and table.find(team.actors, actor) then
								return true
							end
						end
						return false
					end,
					optedIn = function(actor: string): boolean
						return joined[actor] == true
					end,
				}
			end,
		})
		local contract = table.clone(Runtime)
		contract.actions = table.clone(Runtime.actions)
		local clientActions, serverActions = {}, {}
		for _, action in contract.actions do
			table.insert(
				if action.origin == "server" then serverActions else clientActions,
				"survival-coop:" .. action.id
			)
		end
		local clanPort: any = table.clone(clan)
		local outpostPort: any = table.clone(outpost)
		clanPort.close, outpostPort.close = nil, nil
		local personalBackend = {
			update = function(key: string, transform: any): (boolean, any)
				return ctx.backend.update("clan-fixture-player:" .. key, transform)
			end,
		}
		session = Session.new(
			{
				packConfig = {
					api = 1,
					order = { "survival-coop" },
					configs = { ["survival-coop"] = AdapterFixture.config },
				},
				contracts = { contract },
				controls = {},
				storeName = "ClanFixture",
			},
			personalBackend,
			{
				sessionId = "clan-personal-" .. tostring(generation),
				lockTimeout = 86400,
				retries = 0,
				now = function(): number
					return now
				end,
			},
			{
				now = function(): number
					return now
				end,
				roll = function(): number
					return 0
				end,
				emit = function() end,
				survivalExtensions = { clanPort, outpostPort },
			},
			{ actions = clientActions, serverActions = serverActions, windowSeconds = 86400, maxOutcomes = 4096 }
		)
		for actor in joined do
			assert(session.join(actor).ok, "clan invariant: 88")
		end
	end
	local fixture: any = { services = {} }
	create()
	function fixture.command(actor: string, prefix: string, operation: string, args: any, fixed: string?): any
		if not joined[actor] then
			assert(session.join(actor).ok, "clan invariant: 93")
			joined[actor] = true
		end
		request += 1
		local server = prefix == "outpost"
			or operation == "deposit"
			or operation == "withdraw"
			or operation == "contribute"
		local fn = if server then session.commandServer else session.command
		return fn(actor, {
			requestId = fixed or tostring(request),
			sessionEpoch = session.commandEpoch(actor),
			action = "survival-coop:" .. prefix .. "-" .. operation,
			args = { if prefix == "clan" then "alpha" else "central", args },
		})
	end
	function fixture.snapshot(): any
		return { clan = clan.snapshot("owner"), outpost = outpost.snapshot("owner") }
	end
	function fixture.reconnect(): string?
		for actor in joined do
			if not session.close(actor).ok then
				return "session close failed"
			end
		end
		if not clan.close().ok or not outpost.close().ok then
			return "aggregate close failed"
		end
		create()
		return nil
	end
	function fixture.advance(value: number, actors: any)
		now += value
		occupants = actors
	end
	function fixture.joinAll()
		for _, team in teams do
			for _, actor in team.actors do
				if not joined[actor] then
					assert(session.join(actor).ok, "clan invariant: 111")
					joined[actor] = true
				end
			end
		end
	end
	function fixture.close(): any
		for actor in joined do
			local result = session.close(actor)
			if not result.ok then
				return result
			end
		end
		local result = clan.close()
		return if result.ok then outpost.close() else result
	end
	return fixture
end
return M
