--!strict
-- Host-only (luau-lsp lune set): the robango-island generated catalog is not mounted by other game packs; marker: require("@lune/task")
local Commands = require("./MultistoreyCommands")
local Documents = require("../../../core/infra/data/ActorDocumentStore")
local Memory = require("../../../core/infra/data/MemoryBackend")
local Data = require("../../../core/domain/genre/SerializedData")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")

return {
	["building commits support topology and kit debit under the same personal fence"] = function()
		local content = Data.clone(Content)
		content.buildingPolicy = {
			cellStuds = 16,
			stairSteps = 12,
			kits = { floor = "floor-kit", pillar = "pillar-kit", stairs = "stairs-kit" },
		}
		local memory = Memory.new()
		local documents = Documents.new(memory, {
			sessionId = "builder",
			leaseSeconds = 30,
			now = function()
				return 0
			end,
		}, "build-test")
		local allowed, occupied = true, false
		local calls = 0
		local commands = Commands.new(documents, content, function()
			return { allowed = allowed, inBounds = true, reachable = true, occupied = occupied }
		end, function(document, consume, grant)
			calls += 1
			document.debits = (document.debits or 0) + #consume - #grant
			return nil
		end)
		local function place(id: string, kind: string, floor: number, version: number): any
			return commands.command(
				"123",
				id,
				"place",
				{ version = version, part = { id = id, kind = kind, floor = floor, x = 0, z = 0 } }
			)
		end
		assert(not place("unsupported", "floor", 2, 0).ok and calls == 0, "unsupported does not debit")
		allowed = false
		assert(not place("floor", "floor", 1, 0).ok and calls == 0, "permission checked inside transaction")
		allowed = true
		assert(place("floor", "floor", 1, 0).ok, "base floor")
		assert(place("floor", "floor", 1, 0).ok and calls == 1, "request replay does not debit twice")
		assert(not place("floor", "pillar", 1, 1).ok, "request body conflict")
		assert(place("pillar", "pillar", 1, 1).ok, "support")
		assert(place("stairs", "stairs", 1, 2).ok, "access")
		assert(place("upper", "floor", 2, 3).ok, "supported upper floor")
		assert(
			not commands.command("123", "remove", "remove", { version = 4, id = "pillar" }).ok,
			"support removal refused"
		)
		occupied = true
		assert(
			not commands.command("123", "occupied", "remove", { version = 4, id = "upper" }).ok,
			"occupied storage protected"
		)
		occupied = false
		memory.failNext(1)
		assert(
			not commands.command("123", "remove-upper", "remove", { version = 4, id = "upper" }).ok,
			"storage failure refuses"
		)
		local state = documents.snapshot("123")
		assert(state.multistorey.version == 4 and state.debits == 4, "failed removals preserve kits and topology")
		for _, box in commands.geometry(state.multistorey) do
			assert(box.canCollide, "production geometry collidable")
		end
		assert(documents.close().ok, "builder released")
	end,
}
