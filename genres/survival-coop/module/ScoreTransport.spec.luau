--!strict
local Transport = require("./ScoreTransport")
local Rules = require("../../../core/domain/music/TestCatalog")
local serde = require("@lune/serde")
local Session = require("../../../core/infra/genre/Session")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Schema = require("../../../core/infra/net/Schema")
return {
	["chunk commands traverse actual Session validation fencing and durable dispatch"] = function()
		local saves = 0
		local extension = Transport.new({
			rules = Rules,
			uploadTtl = 60,
			now = function()
				return 0
			end,
			decode = function(text)
				return serde.decode("json", text)
			end,
			repository = {
				save = function()
					saves += 1
					return { ok = true, data = { scoreId = "1:score:1", revision = 1 } }
				end,
			},
		})
		local text = Schema.string({ maxLen = 256 })
		local definitions: any = {
			["score-upload-begin"] = {
				text,
				Schema.number({ min = 1, max = Rules.maxBytes, integer = true }),
				text,
				text,
			},
			["score-upload-chunk"] = {
				text,
				Schema.number({ min = 1, max = math.ceil(Rules.maxBytes / 128), integer = true }),
				text,
			},
			["score-upload-commit"] = { text },
			["score-upload-cancel"] = {},
		}
		local actions, ids = {}, {}
		for id, args in definitions do
			table.insert(
				actions,
				{ id = id, args = args, origin = "client", rate = { capacity = 100, refillPerSecond = 100 } }
			)
			table.insert(ids, "survival-coop:" .. id)
		end
		local contract: any = {
			api = 1,
			id = "survival-coop",
			configVersion = 1,
			saveVersion = 1,
			actions = actions,
			events = {},
			hooks = {},
			validateConfig = function()
				return {}
			end,
			validateSave = function()
				return {}
			end,
			create = function()
				return {
					join = function()
						return { ok = true }
					end,
					leave = function() end,
					dispatch = function()
						return { ok = false }
					end,
					advance = function() end,
					snapshot = function()
						return {}
					end,
					save = function()
						return {}
					end,
				}
			end,
		}
		local policy = { actions = ids }
		local session = Session.new(
			{
				packConfig = { api = 1, order = { "survival-coop" }, configs = { ["survival-coop"] = {} } },
				contracts = { contract },
				controls = {},
				storeName = "MusicTransportSpec",
				durable = policy,
			} :: any,
			Memory.new(),
			{
				sessionId = "music",
				lockTimeout = 120,
				retries = 0,
				now = function()
					return 0
				end,
			},
			{
				now = function()
					return 0
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
				encode = function(value)
					return serde.encode("json", value)
				end,
				survivalExtensions = { extension },
			},
			policy
		)
		assert(session.join("1").ok, "Session actor joined")
		local request = 0
		local function send(action: string, args: { any }): any
			request += 1
			return session.command("1", {
				action = action,
				args = args,
				requestId = tostring(request),
				sessionEpoch = session.commandEpoch("1"),
			})
		end
		local score: any = { version = 1, tempo = 120, parts = {} }
		for _ = 1, 6 do
			table.insert(score.parts, {
				instrumentId = "piano",
				notes = { { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 } },
			})
		end
		local encoded = serde.encode("json", score)
		assert(
			#encoded > 256
				and Transport.send({ rules = Rules, send = send }, encoded, nil, "sessionUpload").ok
				and saves == 1,
			"real Session receives full score"
		)
		assert(
			not send("survival-coop:score-upload-chunk", { "sessionUpload", 1, string.rep("a", 257) }).ok and saves == 1,
			"Session original cap retained"
		)
	end,
	["ordinary multi-part score travels only bounded command text and fences before writes"] = function()
		local saves, calls = 0, 0
		local allowed = true
		local receiver = Transport.new({
			rules = Rules,
			uploadTtl = 60,
			now = function()
				return 1
			end,
			decode = function(text: string)
				return serde.decode("json", text)
			end,
			repository = {
				save = function(actor: string, _id: string?, score: any, receipt: string)
					assert(
						actor == "a" and #score.parts == 6 and (receipt == "upload" or receipt == "upload2"),
						"authenticated context"
					)
					saves += 1
					return { ok = true, data = { scoreId = "a:score:1", revision = 1 } }
				end,
			},
		})
		local function send(action: string, args: { any }): any
			assert(receiver.handles(action), "command routed")
			for _, arg in args do
				if type(arg) == "string" then
					assert(#arg <= 256 and utf8.len(arg), "Session text boundary")
				end
			end
			calls += 1
			return receiver.command("a", action, args, {}, {}, function()
				return { ok = allowed, reason = "fenced" }
			end)
		end
		local score: any = { version = 1, tempo = 120, parts = {} }
		for _ = 1, 6 do
			table.insert(score.parts, {
				instrumentId = "piano",
				notes = { { startTick = 0, durationTicks = 480, pitch = 60, velocity = 100 } },
			})
		end
		local text = serde.encode("json", score)
		assert(#text > 256, "requires chunking")
		local ctx = { rules = Rules, send = send }
		assert(Transport.send(ctx, text, nil, "upload").ok and saves == 1 and calls > 3, "assembled score saved")
		allowed = false
		assert(not send("survival-coop:score-upload-commit", { "upload" }).ok and saves == 1, "fenced no write")
		receiver.disconnect("a")
		allowed = true
		assert(not send("survival-coop:score-upload-commit", { "upload" }).ok, "disconnect drops memory")
		assert(Transport.send(ctx, text, nil, "upload2").ok and saves == 2, "successful transfer releases actor slot")
	end,
	["malformed upload never reaches repository and sender refuses oversized locally"] = function()
		local saves = 0
		local receiver = Transport.new({
			rules = Rules,
			uploadTtl = 60,
			now = function()
				return 0
			end,
			decode = function(text: string)
				return serde.decode("json", text)
			end,
			repository = {
				save = function()
					saves += 1
				end,
			},
		})
		local ctx = {
			rules = Rules,
			send = function(action: string, args: { any })
				return receiver.command("a", action, args, {}, {}, function()
					return { ok = true }
				end)
			end,
		}
		assert(not Transport.send(ctx, "{", nil, "bad").ok and saves == 0, "malformed no write")
		assert(
			not Transport.send(ctx, string.rep("x", Rules.maxBytes + 1), nil, "large").ok and saves == 0,
			"oversized no write"
		)
	end,
}
