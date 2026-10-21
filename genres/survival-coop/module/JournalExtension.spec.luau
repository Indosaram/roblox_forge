--!strict
local Journal = require("./JournalExtension")
local Chapters = require("../../../core/domain/journal/Chapters")

local function fixture(): any
	local f: any = { document = { level = 1, coins = 0 }, writesFail = false, grantFail = false, resolved = 0 }
	local catalog = {
		{
			id = "first",
			gates = { characterLevel = 1 },
			objectives = { { id = "gather", action = "gather", target = "wood", quantity = 1 } },
			rewards = { coins = 5 },
		},
	}
	f.context = {
		content = { chapters = catalog },
		journal = {
			update = function(_actor: string, transform: (any) -> any): (boolean, string?)
				local candidate = transform(f.document)
				if f.writesFail then
					return false, "WRITE_FAILED"
				end
				f.document = candidate
				return true, nil
			end,
			read = function(_actor)
				return f.document
			end,
			level = function(document)
				return document.level
			end,
			grant = function(document: any, rewards: any, _chapter)
				document.coins += rewards.coins
				return if f.grantFail then "GRANT_FAILED" else nil
			end,
			evidence = function(_actor, _action, _args, _result)
				f.resolved += 1
				return { id = "settled", action = "gather", target = "wood", quantity = 1 }
			end,
		},
	}
	f.extension = Journal.factory(f.context)
	f.command = function(action, args, request)
		return f.extension.command(
			"actor",
			"survival-coop:journal-" .. action,
			args,
			{ requestId = request },
			"client",
			function()
				return { ok = true }
			end
		)
	end
	return f
end

return {
	["failed commands cannot supply journal evidence"] = function()
		local f = fixture()
		assert(f.command("open", { "first" }, "open").ok, "open")
		f.extension.observe("actor", "gather", {}, { ok = false })
		assert(f.resolved == 0 and next(f.document.journal.counts) == nil, "failed-command evidence admission")
	end,
	["claims persist once across reconnect and request bindings cannot change"] = function()
		local f = fixture()
		assert(f.command("open", { "first" }, "open").ok, "open")
		local incomplete = f.command("claim", {}, "early")
		assert(not incomplete.ok and incomplete.reason == "OBJECTIVES_INCOMPLETE", "incomplete claim")
		local conflict = f.command("claim", {}, "open")
		assert(not conflict.ok and conflict.reason == "REQUEST_CONFLICT", "request binding")
		assert(f.extension.observe("actor", "gather", {}, { ok = true }).ok, "settled evidence")
		assert(f.command("claim", {}, "claim").ok and f.document.coins == 5, "fixed grant")
		f.extension = Journal.factory(f.context)
		assert(f.command("claim", {}, "claim").ok and f.document.coins == 5, "reconnect replay grants once")
		assert(f.extension.snapshot("actor").completed.first, "persisted completion")
	end,
	["reward refusal and storage failure preserve the original aggregate"] = function()
		local f = fixture()
		assert(f.command("open", { "first" }, "open").ok, "open")
		assert(f.extension.observe("actor", "gather", {}, { ok = true }).ok, "settled evidence")
		local original = f.document
		f.grantFail = true
		local refused = f.command("claim", {}, "claim")
		assert(not refused.ok and refused.reason == "GRANT_FAILED", "reward refusal")
		assert(f.document == original and f.document.coins == 0, "failed reward mutation rolled back")
		f.grantFail, f.writesFail = false, true
		local failed = f.command("claim", {}, "claim")
		assert(not failed.ok and failed.reason == "WRITE_FAILED", "storage failure surfaced")
		assert(f.document == original and not f.document.journal.completed.first, "failed write not committed")
		f.writesFail = false
		assert(f.command("claim", {}, "claim").ok and f.document.coins == 5, "retry grants exactly once")
		assert(Chapters.restore(f.document.journal, f.context.content.chapters).completed.first, "valid saved state")
	end,
}
