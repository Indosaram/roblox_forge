--!strict
-- Host-only (luau-lsp lune set): the robango-island generated catalog is not mounted by other game packs; marker: require("@lune/task")
local Ports = require("./JournalPorts")
local Extension = require("./JournalExtension")
local Feed = require("./JournalObjectiveFeed")
local Documents = require("../../../core/infra/data/ActorDocumentStore")
local Data = require("../../../core/domain/genre/SerializedData")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local Catalog = assert(Content.chapters, "journal catalog required")
local Fenced = require("../../../core/infra/data/FencedStore")
local Memory = require("../../../core/infra/data/MemoryBackend")

return {
	["pending objective survives a fresh feed and delivery acknowledgement loss"] = function()
		local document: any = {
			journal = { version = 1, active = Catalog[1].id, completed = {}, counts = {}, receipts = {}, markers = {} },
		}
		local failRemoval = false
		local port = {
			read = function(): any
				return Data.clone(document)
			end,
			update = function(_actor: string, transform: any): (boolean, string?)
				local candidate = transform(Data.clone(document))
				if failRemoval and candidate.journalPending and not candidate.journalPending.job then
					failRemoval = false
					return false, "ACK_LOST"
				end
				document = candidate
				return true, nil
			end,
		}
		local feed = Feed.new(port, Content, {})
		assert(feed.stage("owner", "job", { chapterId = Catalog[1].id }).ok, "stage objective before command")
		feed.close()
		feed = Feed.new(port, Content, {})
		local function resolve(): any
			return {
				{
					receiptId = "survey-job",
					action = "survey",
					target = "rw.explore20.objective",
					quantity = 1,
					marker = "marker",
				},
			}
		end
		failRemoval = true
		assert(not feed.recover("owner", resolve).ok, "lost delivery acknowledgement remains pending")
		assert(document.journalPending.job ~= nil, "pending receipt retained")
		assert(feed.recover("owner", resolve).ok, "fresh retry settles pending event")
		assert(document.journal.counts[Catalog[1].objectives[1].id] == 1, "exactly one checkpoint credit")
		assert(document.journalPending.job == nil, "acknowledged delivery removed")
	end,
	["Session bridge shares the existing personal aggregate and installs only committed tokens"] = function()
		local memory = Memory.new()
		local store = Fenced.new(memory, {
			sessionId = "live",
			leaseSeconds = 30,
			now = function()
				return 0
			end,
		})
		local profile = assert(
			store:acquire("personal:123", function()
				return { envelope = { genres = { ["survival-coop"] = { data = { balance = 7 } } } } }
			end),
			"personal acquired"
		)
		local installs = 0
		local bridge = Ports.personal({
			personalTransfer = function(actor: string): any
				if actor ~= "123" then
					return nil
				end
				return {
					personal = store,
					profile = function()
						return profile
					end,
					install = function(token)
						profile = token
						installs += 1
					end,
				}
			end,
		})
		assert(
			bridge.transaction("123", function(data: any)
				data.balance += 2
				return { ok = true }
			end).ok,
			"personal mutation committed"
		)
		assert(bridge.snapshot("123").balance == 9 and installs == 1, "same owner installed")
		assert(not bridge.transaction("123", function(data)
			data.balance = 0
			return { ok = false }
		end).ok, "refusal preserved")
		memory.failNext(1)
		assert(not bridge.transaction("123", function(data)
			data.balance = 0
			return { ok = true }
		end).ok, "failed commit refused")
		assert(bridge.snapshot("123").balance == 9 and installs == 2, "failed candidate not installed")
		assert(bridge.snapshot("999") == nil, "missing session actor refused")
		assert(store:release(profile), "personal owner released")
	end,
	["personal journal CAS retries rollback failures and grant exactly once across handoff"] = function()
		local records = {}
		local fail, ambiguous = false, false
		local service = {}
		function service:UpdateAsync(key: string, transform: any): any
			if fail then
				error("THROTTLED")
			end
			-- Roblox may discard a speculative callback and replay against latest state.
			transform(Data.clone(records[key]))
			local committed = transform(Data.clone(records[key]))
			records[key] = Data.clone(committed)
			if ambiguous then
				error("ACK_LOST")
			end
			return Data.clone(committed)
		end
		local backend = {
			update = function(key, transform)
				return pcall(function()
					return service:UpdateAsync(key, transform)
				end)
			end,
		}
		local function store(id: string): any
			return Documents.new(backend, {
				sessionId = id,
				leaseSeconds = 30,
				now = function()
					return 0
				end,
			}, "journal-test")
		end
		local documents = store("a")
		assert(
			documents.transaction("123", function(document)
				document.balance = 0
				document.progression = { level = 60, xp = 0, sp = 180, version = 0 }
				return { ok = true }
			end).ok,
			"seed personal owner"
		)
		local ports = Ports.new(documents, Content)
		local extension = Extension.factory({ journal = ports, content = Content })
		local function command(action: string, args: any, request: string): any
			return extension.command(
				"123",
				"survival-coop:journal-" .. action,
				args,
				{ requestId = request },
				"client",
				function()
					return { ok = true }
				end
			)
		end
		local chapter = Catalog[1]
		assert(command("open", { chapter.id }, "open").ok, "open persisted")
		local listener: any = nil
		local connected = true
		local signal = {
			Connect = function(_self, callback)
				listener = callback
				return {
					Disconnect = function()
						connected = false
					end,
				}
			end,
		}
		local feed = Feed.new(ports, Content, { gather = signal })
		for index, objective in chapter.objectives do
			local event = {
				actor = "123",
				chapterId = chapter.id,
				committed = true,
				ok = true,
				receiptId = "r" .. index,
				action = objective.action,
				target = objective.target,
				quantity = objective.quantity,
				marker = "marker" .. index,
			}
			local refused = Data.clone(event)
			refused.committed = false
			assert(not feed.accept(refused).ok, "uncommitted producer refused")
			refused = Data.clone(event)
			refused.chapterId = "older"
			assert(not feed.accept(refused).ok, "old chapter receipt refused")
			assert(listener(event).ok, "authoritative checkpoint committed")
			assert(listener(event).ok, "receipt replay idempotent")
		end
		fail = true
		assert(not command("claim", {}, "claim").ok, "failed store never acknowledges grant")
		fail = false
		ambiguous = true
		assert(not command("claim", {}, "claim").ok, "ambiguous acknowledgment is not success")
		ambiguous = false
		assert(command("claim", {}, "claim").ok, "retry finds committed claim")
		local document = documents.snapshot("123")
		assert(document.balance == chapter.rewards.coins, "single coin grant")
		assert(document.progression.xp == chapter.rewards.xp, "single XP grant")
		assert(
			document.missionItems[assert(chapter.rewards.items, "seal rewards required")[1].item] == 1,
			"nontradeable seal ledger"
		)
		assert(ports.grant(document, chapter.rewards, chapter.id) == nil, "grant replay acknowledged")
		assert(document.balance == chapter.rewards.coins, "grant port itself is receipt safe")
		assert(not command("open", { chapter.id }, "claim").ok, "conflicting request refused")
		local other = store("b")
		assert(other.snapshot("123") == nil, "foreign writer fenced")
		assert(documents.releaseActor("123").ok, "release personal document")
		assert(other.snapshot("123").journal.completed[chapter.id], "checkpoint survives fresh owner")
		assert(other.close().ok, "new owner released")
		feed.close()
		assert(not connected, "subscription disconnected")
	end,
	["wallet refusal rolls back checkpoints and reward candidates"] = function()
		local document: any = { balance = 1e9, progression = { level = 20, sp = 60, xp = 0, version = 0 } }
		local ports = Ports.new({}, Content)
		local reason = ports.grant(document, Catalog[1].rewards, Catalog[1].id)
		assert(
			reason == "WALLET_FULL" and document.progression.xp == 0 and document.missionItems == nil,
			"full wallet cannot grant anything"
		)
	end,
}
