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
	["extension registries ship empty"] = function()
		assert(#Extensions.factories == 0, "server registry empty in the seam lane")
		assert(#ExtensionPanels.factories == 0, "client registry empty in the seam lane")
	end,
	["bootstrap builds registered extensions and releases them on close"] = function()
		local seen: any = nil
		local releases = 0
		local factory = assert(build({
			function(ctx)
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
				}
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
			function()
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
				}
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
		local base = crafting.policy()
		local saved = Contract.extensionActions
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
		assert(#crafting.policy().actions == #base.actions, "restored")
	end,
}
