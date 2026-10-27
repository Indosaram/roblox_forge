--!strict
local Fixture = require("../../../cli/forge/fixtures/clan-governance/scenario")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Extension = require("./ClanExtension")
local Fenced = require("../../../core/infra/data/FencedStore")
local Session = require("../../../core/infra/genre/Session")
local Clan = require("../../../core/domain/settlement/Clan")
local Ecology = require("./CombatEcology")
return {
	["clan-browse is an appended client action whose page reaches only the asking actor"] = function()
		local Contract: any = require("./Contract")
		local declared = false
		for _, action in Contract.actions do
			declared = declared or (action.id == "clan-browse" and action.origin == "client")
		end
		local extensionActions = Contract.extensionActions :: { string }
		-- Later appends (C6 rescue, C3 carcass) follow clan-browse; clan-browse follows camp-loan.
		local at = table.find(extensionActions, "clan-browse") :: number
		assert(declared and at == (table.find(extensionActions, "camp-loan") :: number) + 1, "appended after camp-loan")
		for index = at + 1, #extensionActions do
			assert(
				table.find({ "rescue-choose", "rescue-revive", "carcass-take" }, extensionActions[index]),
				"only later extensions follow: " .. extensionActions[index]
			)
		end
		local fs = require("@lune/fs")
		local durable = fs.readFile("games/robango-island/src/shared/GenreDurable.luau")
		assert(string.find(durable, '"survival-coop:clan-browse"', 1, true), "durable policy publishes it")
		local asked: any = nil
		local browser = Extension.browser(function(query: string, page: number, size: number): (any?, string?)
			if query == "down" then
				return nil, "THROTTLED"
			end
			asked = { query, page, size } :: { any }
			return { query = query, page = page, pages = 1, total = 1, rows = { { id = "tide" } } }, nil
		end)
		local function admit(): any
			return { ok = true }
		end
		assert(browser.handles("survival-coop:clan-browse") and not browser.handles("survival-coop:clan-join"), "own")
		assert(browser.snapshot("a") == nil, "no page before asking")
		local result = browser.command("a", "survival-coop:clan-browse", { "ti", 2 } :: { any }, {}, "client", admit)
		assert(result.ok and asked[1] == "ti" and asked[2] == 2 and asked[3] == Extension.BROWSE_PAGE, "page asked")
		assert(browser.snapshot("a").rows[1].id == "tide" and browser.snapshot("b") == nil, "per actor")
		local down = browser.command("a", "survival-coop:clan-browse", { "down", 1 } :: { any }, {}, "client", admit)
		assert(not down.ok and down.reason == "THROTTLED", "a directory failure is not an empty list")
		local release = assert(Session.lifecycle(browser).releaseActor, "lifecycle registered")
		assert(release("a").ok and browser.snapshot("a") == nil, "released")
		assert(Extension.browseFactory({ world = {} }) == nil, "absent without a directory")
	end,
	["fresh clan owner completes durable research without a wallet port"] = function()
		local backend = Memory.new()
		local now = 0
		local store = Fenced.new(backend, {
			sessionId = "research",
			leaseSeconds = 10,
			now = function(): number
				return now
			end,
		})
		local token = assert(store:acquire("clan:alpha", function(): any
			local data = Clan.new("alpha", "owner")
			data.jobs.job = { jobId = "job", definition = "advanced", finishAt = 20, cost = 100, status = "pending" }
			return data
		end))
		assert(store:release(token), "release initial research fence")
		now = 20
		local extension = Extension.new({
			store = function(): any
				return store
			end,
			now = function(): number
				return now
			end,
			owner = function(): string
				return "owner"
			end,
			identity = function(): string
				return "alpha"
			end,
			facts = function(): any
				return { operations = { advanced = { effects = { { id = "advanced-capture", value = 1 } } } } }
			end,
		})
		assert(extension.recover("owner", 8).pending == 0, "overdue research recovered")
		local state = extension.snapshot("owner")
		assert(
			state.jobs.job.status == "completed" and state.research["advanced-capture"] == 1,
			"research effect installed"
		)
		assert(extension.recover("owner", 8).pending == 0, "repeated recovery confirmed")
		assert(extension.snapshot("owner").revision == state.revision, "completion is not paid twice")
		assert(extension.close().ok, "release recovered research fence")
	end,
	["shared clan research changes the real capture eligibility outcome"] = function()
		local clan = Clan.new("alpha", "owner")
		clan.research["advanced-capture"] = 1
		local rules =
			{ basePermille = 650, levelPermille = 10, bonusPermille = 50, minPermille = 200, maxPermille = 900 }
		local facts = {
			survival3 = true,
			stunned = true,
			occupied = 0,
			capacity = 8,
			rope = 1,
			survivalSkill = 40,
			survival6 = false,
			clanResearch = false,
			stronghold = false,
		}
		local species = { captureClass = "advanced", level = 40 }
		local allowed = Clan.effect(clan, "owner", "advanced-capture", 10, { owner = "alpha", expiresAt = 20 })
		facts.clanResearch, facts.stronghold = allowed, allowed
		local result, rope, reason = Ecology.rollCapture(species, facts, rules, 42)
		assert(result ~= nil and rope == 0 and reason == nil, "research enables real capture attempt")
		allowed = Clan.effect(clan, "owner", "advanced-capture", 20, { owner = "alpha", expiresAt = 20 })
		facts.clanResearch, facts.stronghold = allowed, allowed
		result, rope, reason = Ecology.rollCapture(species, facts, rules, 42)
		assert(result == nil and rope == 1 and reason ~= nil, "expired ownership refuses before consuming rope")
	end,
	["clan stale fence and released actor cannot mutate shared aggregate"] = function()
		local backend = Memory.new()
		local now = 0
		local extension = Extension.new({
			store = function(): any
				return Fenced.new(backend, {
					sessionId = "old",
					leaseSeconds = 10,
					now = function(): number
						return now
					end,
				})
			end,
			now = function(): number
				return now
			end,
			owner = function(): string
				return "owner"
			end,
			identity = function(): string
				return "alpha"
			end,
			facts = function(): any
				return {}
			end,
		})
		assert(extension.snapshot("owner"), "open original fence")
		now = 11
		local thief = Fenced.new(backend, {
			sessionId = "new",
			leaseSeconds = 10,
			now = function(): number
				return now
			end,
		})
		local token = assert(
			thief:acquire("clan:alpha", function(data: any): any
				return data
			end),
			"steal expired fence"
		)
		local function command(): any
			local args: { any } = { "alpha", { target = "helper" } }
			return extension.command(
				"owner",
				"survival-coop:clan-invite",
				args,
				{ actorId = "owner", requestId = "one", sessionEpoch = 1 },
				"client",
				function(): any
					return { ok = true }
				end
			)
		end
		assert(command().reason == "lease lost", "stale fence rejects transform")
		assert(thief:release(token), "release stolen fence")
		assert(assert(Session.lifecycle(extension).releaseActor)("owner").ok, "release actor")
		assert(command().reason == "ACTOR_LEFT_OR_FORBIDDEN", "departed actor cannot reacquire")
		assert(assert(Session.lifecycle(extension).resumeActor)("owner").ok, "resume actor")
		assert(command().ok, "resumed actor reacquires")
		assert(extension.close().ok, "close fence")
	end,
	["clan Session commands enforce membership and persist grants over reconnect"] = function()
		local fixture = Fixture.new({
			backend = Memory.new(),
			now = function(): number
				return 10
			end,
		})
		assert(fixture.command("owner", "clan", "invite", { target = "helper" }).ok, "clan invariant: 7")
		assert(fixture.command("helper", "clan", "join", {}).ok, "clan invariant: 8")
		assert(
			not fixture.command("helper", "clan", "role", { target = "helper", role = "officer" }).ok,
			"clan invariant: 9"
		)
		assert(
			fixture.command("owner", "clan", "role", { target = "helper", role = "officer" }).ok,
			"clan invariant: 10"
		)
		assert(
			fixture.command("owner", "clan", "capability", { target = "helper", enabled = true }).ok,
			"clan invariant: 11"
		)
		assert(fixture.command("helper", "clan", "relocate", { territory = "north" }).ok, "clan invariant: 12")
		assert(fixture.reconnect() == nil, "clan invariant: 13")
		assert(fixture.snapshot().clan.members.helper.withdraw, "clan invariant: 14")
		assert(fixture.command("helper", "clan", "leave", {}).ok, "clan invariant: 15")
		assert(
			fixture.command("helper", "clan", "withdraw", { amount = 1 }).reason == "NOT_MEMBER",
			"clan invariant: 16"
		)
		assert(
			fixture.command("helper", "clan", "research-start", { id = "clan-research-exploration" }).reason
				== "NOT_MEMBER",
			"clan invariant: 17"
		)
		assert(fixture.close().ok, "clan invariant: 18")
	end,
}
