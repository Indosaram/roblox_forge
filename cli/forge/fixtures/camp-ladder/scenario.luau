--!strict
-- Native authority for the camp-ladder scenario: the production tribe owner plus the
-- production CampExtension, built from the pack's own content.yml. All commands and
-- assertions stay in qaharness; this file only supplies trusted ports.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Services = require("../../../../genres/survival-coop/module/SurvivalServices")
local CampExtension = require("../../../../genres/survival-coop/module/CampExtension")
local Content = require("../../../../core/domain/survival/Content")
local Job = require("../../../../core/domain/crafting/Job")
local Settlement = require("../../../../core/domain/settlement/Settlement")
local Inventory = require("../../../../core/domain/inventory/Inventory")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Session = require("../../../../core/infra/genre/Session")
local Contract = require("../../../../core/domain/genre/Contract")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local M = {}
-- Trusted friendship source standing in for Players:IsFriendsWithAsync.
local FRIENDS: { [string]: { [string]: boolean } } = { owner = { guest = true } }
function M.new(packPath: string, backend: ProfileStore.Backend, now: () -> number)
	local content = assert(Content.canonicalize(serde.decode("yaml", fs.readFile(packPath .. "/content.yml"))))
	local options = {
		sessionId = "camp-ladder-owner",
		leaseSeconds = 120,
		now = now,
		budget = {
			encode = function(value: any): string
				return serde.encode("json", value)
			end,
		},
	}
	local factory = assert(Services.new({
		tribes = {
			{
				key = "qa-tribe",
				now = now,
				catalog = Job.catalog(content),
				definitions = {},
				initial = {
					settlement = Settlement.new(
						{ tribeId = "tribe", width = 32, depth = 32, cellStuds = 4, maxMembers = 4 },
						"owner"
					),
					warehouse = Inventory.new(
						"warehouse",
						{ slots = 20, softWeightMilli = 60000, hardWeightMilli = 90000 }
					),
				},
				verifyTransfer = function(actor, proof)
					return actor == proof
				end,
			},
		},
		maxServerPlayers = 8,
		maxPlots = 4,
		maxReceipts = 4096,
		-- Even a visitor or stranger routed here must fail membership authority.
		tribeFor = function()
			return "tribe"
		end,
		authorize = function()
			return { ok = true }
		end,
		consent = function(actor, target)
			return actor == "owner" and target ~= "owner"
		end,
		proof = function(actor)
			return actor
		end,
	}, backend, options))
	local session: Session.Session? = nil
	local extension = assert(CampExtension.new({
		content = content,
		store = function()
			return Fenced.new(backend, options)
		end,
		now = now,
		settlement = factory.services.survivalSettlement :: any,
		personalTransfer = function(actor)
			return if session then session.personalTransfer(actor) else nil
		end,
		isFriend = function(host, visitor)
			return FRIENDS[host] ~= nil and FRIENDS[host][visitor] == true
		end,
		visitSeconds = 30,
	}))
	local port: any = table.clone(extension)
	port.close = nil
	local services = table.clone(factory.services)
	services.survivalExtensions = { port }
	return {
		services = services,
		bind = function(value: Session.Session)
			session = value
			factory.bind(value)
		end,
		close = function(): Contract.Result
			local released = (extension.close :: () -> Contract.Result)()
			if not released.ok then
				return released
			end
			return factory.close()
		end,
	}
end
return M
