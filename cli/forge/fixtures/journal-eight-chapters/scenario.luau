--!strict
-- Real Session dispatch + JournalExtension; the external objective producers are
-- injected trusted ports in this lane. This is not a world-navigation proof.
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../genres/survival-coop/module/Contract")
local Config = require("../../../../games/robango-island/src/shared/GenreConfig")
local Content: any = require("../../../../games/robango-island/src/shared/SurvivalContent")
local Schema = require("../../../../core/infra/net/Schema")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Extension = require("../../../../genres/survival-coop/module/JournalExtension")
local Chapters = require("../../../../core/domain/journal/Chapters")
local serde = require("@lune/serde")
local M = {}
M.operations = {
	journal_chapters = function(ctx, step): string?
		local actor = ctx.playerOf(step)
		local err = ctx.fixture.run(actor)
		ctx.results[actor] = { ok = err == nil }
		return err
	end,
}
function M.new(ctx: any): any
	local store = Fenced.new(ctx.backend, {
		sessionId = "journal-fixture",
		leaseSeconds = 120,
		now = ctx.now,
		budget = {
			encode = function(value)
				return serde.encode("json", value)
			end,
		},
	})
	local token: any = nil
	local session: any = nil
	local trusted: any = nil
	local sequence = 0
	local function create()
		local extension = assert(
			Extension.factory({
				content = Content,
				journal = {
					update = function(_actor, transform)
						local updated, err = store:update(token, transform)
						token = updated or token
						return updated, err
					end,
					read = function()
						return token.data
					end,
					level = function(document)
						return document.level
					end,
					grant = function(document: any, rewards: any, chapter: string)
						assert(not document.awards[chapter], "duplicate grant")
						document.awards[chapter] = Chapters.copy(rewards)
						document.coins += rewards.coins
						return nil
					end,
					evidence = function(_actor, _action, _args, result)
						return if trusted and result.ok then trusted else nil
					end,
				},
			}),
			"scenario.luau: invariant at line 38"
		)
		local contract: any = table.clone(Contract)
		contract.actions = table.clone(Contract.actions)
		contract.extensionActions = table.clone(assert(Contract.extensionActions, "extension actions required"))
		for _, name in { "journal-fixture-event" } do
			local args: { any } = if name == "journal-open" then { Schema.string({ maxLen = 128 }) } else {}
			table.insert(contract.actions, {
				id = name,
				args = args,
				origin = "client",
				rate = { capacity = 100, refillPerSecond = 100 },
			})
			table.insert(contract.extensionActions, name)
		end
		local eventPort = {
			id = "journal-evidence-source",
			handles = function(action)
				return action == "survival-coop:journal-fixture-event"
			end,
			command = function(_actor, _action, _args, _context, _origin, admit)
				return admit()
			end,
		}
		session = Session.new(
			{
				packConfig = Config,
				contracts = { contract },
				controls = {},
				storeName = "journal-session",
			},
			ctx.backend,
			{ sessionId = "journal-session", lockTimeout = 120, retries = 0, now = ctx.now },
			{
				now = ctx.clock.now,
				roll = function()
					return 0
				end,
				emit = function() end,
				encode = function(value)
					return serde.encode("json", value)
				end,
				survivalExtensions = { extension, eventPort },
			},
			{
				actions = {
					"survival-coop:journal-open",
					"survival-coop:journal-claim",
					"survival-coop:journal-fixture-event",
				},
			}
		)
	end
	local function request(actor, action, args)
		sequence += 1
		local qualified = "survival-coop:" .. action
		return {
			requestId = "journal:" .. sequence,
			sessionEpoch = session.commandEpoch(actor, qualified),
			action = qualified,
			args = args,
		}
	end
	return {
		run = function(actor): string?
			token = assert(
				store:acquire("journal:" .. actor, function(data)
					return if next(data) == nil then { level = 19, coins = 0, awards = {} } else data
				end),
				"scenario.luau: invariant at line 125"
			)
			create()
			assert(session.join(actor).ok, "scenario.luau: invariant at line 129")
			local locked = session.command(actor, request(actor, "journal-open", { Content.chapters[1].id }))
			assert(not locked.ok and locked.reason == "LEVEL_GATE", "scenario.luau: invariant at line 131")
			token = assert(
				store:update(token, function(data)
					data.level = 60
					return data
				end),
				"scenario.luau: invariant at line 132"
			)
			assert(
				session.command(actor, request(actor, "journal-open", { Content.chapters[2].id })).reason
					== "CHAPTER_ORDER",
				"scenario.luau: invariant at line 136"
			)
			local coins = 0
			for _, chapter in Content.chapters do
				assert(
					session.command(actor, request(actor, "journal-open", { chapter.id })).ok,
					"scenario.luau: invariant at line 142"
				)
				assert(
					session.command(actor, request(actor, "journal-claim", {})).reason == "OBJECTIVES_INCOMPLETE",
					"scenario.luau: invariant at line 143"
				)
				for _, objective in chapter.objectives do
					for count = 1, objective.quantity do
						trusted = {
							id = objective.id .. count,
							action = objective.action,
							target = objective.target,
							quantity = 1,
							marker = tostring(count),
						}
						assert(
							session.command(actor, request(actor, "journal-fixture-event", {})).ok,
							"scenario.luau: invariant at line 153"
						)
						trusted = nil
						assert(session.close(actor).ok, "scenario.luau: invariant at line 155")
						create()
						assert(session.join(actor).ok, "scenario.luau: invariant at line 157")
						assert(token.data.journal.counts[objective.id] == count, "scenario.luau: invariant at line 158")
					end
				end
				local claim = request(actor, "journal-claim", {})
				assert(session.command(actor, claim).ok, "scenario.luau: invariant at line 162")
				assert(session.command(actor, claim).ok, "scenario.luau: invariant at line 163")
				coins += chapter.rewards.coins
				assert(
					token.data.coins == coins and token.data.awards[chapter.id],
					"scenario.luau: invariant at line 165"
				)
			end
			assert(session.close(actor).ok, "scenario.luau: invariant at line 167")
			return nil
		end,
		snapshot = function()
			return if token then token.data else {}
		end,
		close = function()
			if token then
				local ok, err = store:release(token)
				token = nil
				return { ok = ok ~= nil, reason = err }
			end
			return { ok = true }
		end,
	}
end
return M
