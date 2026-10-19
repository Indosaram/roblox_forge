--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Bootstrap = require("./SurvivalBootstrap")
local Extensions = require("./Extensions")
local ExtensionPanels = require("./ExtensionPanels")
local Gathering = require("./Gathering")
local Content = require("../../../core/domain/survival/Content")
local Memory = require("../../../core/infra/data/MemoryBackend")

local function content(): any
	local config = serde.decode(
		"yaml",
		fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")
	).genre_contract
	local raw = config.configs["survival-coop"].inventory.content
	raw.nodes = { { id = "tree", respawnMillis = 1000, harvest = { { item = "wood", quantity = 3 } } } }
	return assert(Content.canonicalize(raw))
end

local function build(factories: { Extensions.Factory })
	local document = content()
	local now = function()
		return 0
	end
	local world: Bootstrap.World = {
		services = {},
		bind = function() end,
		destroy = function() end,
		gatheringAccess = function()
			return function()
				return nil
			end
		end,
	}
	return Bootstrap.new(
		{
			settlements = {
				tribes = {},
				maxServerPlayers = 2,
				maxPlots = 1,
				maxReceipts = 16,
				tribeFor = function()
					return nil
				end,
				authorize = function()
					return { ok = true }
				end,
				consent = function()
					return false
				end,
				proof = function()
					return "none"
				end,
			} :: any,
			sourceKey = "nodes:ext",
			initial = Gathering.new("world", document, {
				{
					id = "tree-1",
					catalogId = "tree",
					position = { x = 0, y = 0, z = 0 },
					charges = 1,
					qualityMilli = 1000,
				},
			}),
			content = document,
			now = now,
			nowMillis = now,
			extensions = factories,
		},
		world,
		Memory.new(),
		{
			sessionId = "ext",
			leaseSeconds = 120,
			now = now,
			budget = {
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
		}
	)
end

return {
	["an open panel sheet stays clear of the chat window and the right-hand HUD"] = function()
		local function overlaps(x: number, y: number, w: number, h: number, cr: number, cb: number): boolean
			return x < cr and y < cb and x + w > 0 and y + h > 0
		end
		-- Desktop 1280x720 with the default 512x245 chat (tutorial Studio QA, step 78).
		local w, h = ExtensionPanels.sheetBounds(1280, 720)
		local x, y, fitted = ExtensionPanels.sheetPosition(1280, 720, w, h, 520, 253)
		assert(not overlaps(x, y, w, fitted, 520, 253), "desktop sheet clear of chat")
		assert(x == math.floor((1280 - w) / 2), "desktop sheet keeps its centered column, clear of the HUD stack")
		assert(y + fitted <= 720 - 12 and fitted >= 240, "desktop sheet fits below the chat")
		-- No chat: centered and full height, as before.
		local cx, cy, ch = ExtensionPanels.sheetPosition(1280, 720, w, h, 0, 0)
		assert(
			cx == math.floor((1280 - w) / 2) and cy == math.floor((720 - h) / 2) and ch == h,
			"centered without chat"
		)
		-- Portrait phone: below the chat.
		local pw, ph = ExtensionPanels.sheetBounds(390, 844)
		local px, py, pf = ExtensionPanels.sheetPosition(390, 844, pw, ph, 300, 200)
		assert(not overlaps(px, py, pw, pf, 300, 200) and py + pf <= 844, "phone sheet below chat")
	end,
	["extension registries are tables"] = function()
		assert(type(Extensions.factories) == "table", "server registry present")
		assert(type(ExtensionPanels.factories) == "table", "client registry present")
	end,
	["bootstrap builds registered extensions and releases them on close"] = function()
		local seen: any = nil
		local releases = 0
		local factory = assert(build({
			function(ctx): Extensions.Built?
				seen = ctx
				return {
					id = "fixture",
					handles = function(action)
						return action == "survival-coop:defend-active"
					end,
					command = function()
						return { ok = true }
					end,
					close = function()
						releases += 1
						return { ok = true }
					end,
				} :: any
			end,
			function()
				return nil -- a disabled factory contributes nothing
			end,
		}))
		local list = assert(factory.services.survivalExtensions, "extensions exposed as services")
		assert(#list == 1 and list[1].id == "fixture" and (list[1] :: any).close == nil, "close kept out of the port")
		assert(seen.content and seen.store and #seen.members() == 0, "context supplies content/store/members")
		assert(seen.personalTransfer("1") == nil, "no transfer before bind")
		assert(factory.close().ok, "close")
		assert(releases == 1, "extension resource released on close")
	end,
	["a failing extension release fails close"] = function()
		local factory = assert(build({
			function(): Extensions.Built?
				return {
					id = "stuck",
					handles = function()
						return false
					end,
					command = function()
						return { ok = false }
					end,
					close = function()
						return { ok = false, reason = "STUCK" }
					end,
				} :: any
			end,
		}))
		assert(factory.close().reason == "STUCK", "release failure surfaces")
	end,
	["no registered extensions leaves the service absent"] = function()
		local factory = assert(build({}))
		assert(factory.services.survivalExtensions == nil, "absent when empty")
		assert(factory.close().ok, "close")
	end,
	["durable policy derives extension actions from the genre contract"] = function()
		local Contract: any = require("./Contract")
		local crafting = require("../../../cli/forge/lib/craftinggenerate")
		local saved = Contract.extensionActions
		local restoredCount = #crafting.policy().actions
		Contract.extensionActions = {}
		local base = crafting.policy()
		Contract.extensionActions = { "defend-active", "death-drop" }
		local ok, err = pcall(function()
			local derived = crafting.policy()
			assert(derived.actions[#derived.actions] == "survival-coop:defend-active", "client action appended")
			assert(#derived.actions == #base.actions + 1, "one client action added")
			local server = assert(derived.serverActions, "derived server actions")
			assert(server[#server] == "survival-coop:death-drop", "server action appended by origin")
			Contract.extensionActions = { "not-declared" }
			assert(not pcall(crafting.policy), "undeclared extension action rejected")
			Contract.extensionActions = { "attack" }
			assert(not pcall(crafting.policy), "duplicate of base action rejected")
		end)
		Contract.extensionActions = saved
		assert(ok, err)
		assert(#crafting.policy().actions == restoredCount, "restored")
	end,
}
