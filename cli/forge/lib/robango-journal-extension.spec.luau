--!strict
local Extension = require("../../../genres/survival-coop/module/JournalExtension")
local Content: any = require("../../../games/robango-island/src/shared/SurvivalContent")
local Chapters = require("../../../core/domain/journal/Chapters")
return {
	["atomic journal grant survives reconnect retry and rejects failed or forged events"] = function()
		local document: any = { level = 60, coins = 0 }
		local accepted = false
		local failGrant = false
		local failWrite = false
		local function factory()
			return assert(
				Extension.factory({
					content = Content,
					journal = {
						update = function(_actor: string, transform: any): (boolean?, string?)
							if failWrite then
								return nil, "throttled"
							end
							document = transform(Chapters.copy(document))
							return true, nil
						end,
						read = function()
							return document
						end,
						level = function(value)
							return value.level
						end,
						grant = function(value: any, rewards: any): string?
							value.coins += rewards.coins
							if failGrant then
								return "BAG_FULL"
							end
							return nil
						end,
						evidence = function(_actor, _action, _args, result)
							return if accepted then result.data else nil
						end,
					},
				}),
				"JournalExtension.spec.luau: invariant at line 12"
			)
		end
		local extension = factory()
		local function command(action, args, request)
			return extension.command(
				"actor",
				"survival-coop:" .. action,
				args,
				{ requestId = request },
				"client",
				function()
					return { ok = true }
				end
			)
		end
		local chapter = Content.chapters[1]
		assert(command("journal-open", { chapter.id }, "open").ok, "JournalExtension.spec.luau: invariant at line 55")
		assert(not command("journal-claim", {}, "early").ok, "JournalExtension.spec.luau: invariant at line 56")
		for _, objective in chapter.objectives do
			local result = {
				ok = true,
				data = {
					id = objective.id,
					action = objective.action,
					target = objective.target,
					quantity = 1,
					marker = objective.id,
				},
			}
			extension.observe("actor", "settled", {}, result)
			assert(document.journal.counts[objective.id] == nil, "JournalExtension.spec.luau: invariant at line 69")
			accepted = true
			extension.observe("actor", "settled", {}, { ok = false, data = result.data })
			assert(document.journal.counts[objective.id] == nil, "JournalExtension.spec.luau: invariant at line 72")
			extension.observe("actor", "settled", {}, result)
			accepted = false
		end
		failGrant = true
		assert(
			command("journal-claim", {}, "claim").reason == "BAG_FULL",
			"JournalExtension.spec.luau: invariant at line 77"
		)
		assert(
			document.journal.active == chapter.id and document.coins == 0,
			"JournalExtension.spec.luau: invariant at line 78"
		)
		failGrant, failWrite = false, true
		assert(
			command("journal-claim", {}, "claim").reason == "throttled",
			"JournalExtension.spec.luau: invariant at line 80"
		)
		failWrite = false
		assert(command("journal-claim", {}, "claim").ok, "JournalExtension.spec.luau: invariant at line 82")
		extension = factory()
		assert(
			command("journal-claim", {}, "claim").ok and document.coins == chapter.rewards.coins,
			"JournalExtension.spec.luau: invariant at line 84"
		)
		assert(
			command("journal-open", { chapter.id }, "claim").reason == "REQUEST_CONFLICT",
			"JournalExtension.spec.luau: invariant at line 85"
		)
	end,
}
