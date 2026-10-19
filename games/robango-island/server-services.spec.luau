--!strict
-- Server.start validates the bootstrap's published services through Options.validate. This boots the
-- pack's real SurvivalFactory with its real WildlifePolicy and TamingConfig (the shape Studio starts)
-- and runs that same validation, so a port that grows an unvalidated field fails here, not in Studio.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local task = require("@lune/task")

local Bootstrap = require("../../genres/survival-coop/module/SurvivalBootstrap")
local Gathering = require("../../genres/survival-coop/module/Gathering")
local Wildlife = require("../../genres/survival-coop/module/Wildlife")
local TamingExtension = require("../../genres/survival-coop/module/TamingExtension")
local Contract = require("../../genres/survival-coop/module/Contract")
local Settlement = require("../../core/domain/settlement/Settlement")
local Inventory = require("../../core/domain/inventory/Inventory")
local Job = require("../../core/domain/crafting/Job")
local Journal = require("../../core/domain/command/Journal")
local Clock = require("../../core/infra/genre/Clock")
local Options = require("../../core/infra/genre/Options")
local Memory = require("../../core/infra/data/MemoryBackend")
local content = require("./src/shared/SurvivalContent")
local source = require("./src/shared/SurvivalWorldConfig")
local wildlifePolicy = require("./src/shared/WildlifePolicy")
local tamingPolicy = require("./src/shared/TamingConfig")

local PACK = "games/robango-island"
local forge = {
	genres = {
		["survival-coop"] = { module = { SurvivalBootstrap = Bootstrap, Gathering = Gathering, Wildlife = Wildlife } },
	},
	core = {
		domain = {
			settlement = { Settlement = Settlement },
			inventory = { Inventory = Inventory },
			crafting = { Job = Job },
			command = { Journal = Journal },
		},
		infra = { genre = { Clock = Clock } },
	},
}
local environment: any = {
	game = {
		GetService = function()
			return {
				WaitForChild = function()
					return forge
				end,
			}
		end,
	},
	task = task,
	Vector3 = {
		new = function(x, y, z)
			return { X = x, Y = y, Z = z }
		end,
	},
	require = function(value)
		return value
	end,
}
local function module(name: string): any
	return luau.load(fs.readFile(PACK .. "/src/server/" .. name .. ".luau"), { environment = environment })()
end

return {
	["the real factory with wildlife and taming publishes services Options.validate accepts"] = function()
		local Provision = module("SurvivalProvision")
		local Factory = module("SurvivalFactory")
		local provision = Provision(
			{ provisionId = "camp", policy = "public", ownerId = "", acceptedInvitations = {}, actors = {} },
			source.tribe.config.tribeId,
			{ studio = false, server = "job:services" }
		)
		local world: any = {
			services = {
				survivalSpatial = {
					campfire = function()
						return nil
					end,
					station = function()
						return nil
					end,
				},
			},
			settlementPorts = function()
				return {
					warehouse = function()
						return true
					end,
					verify = function()
						return true
					end,
					publish = function() end,
				}
			end,
			gatheringAccess = function()
				return function()
					return nil
				end
			end,
			wildlifeAccess = function()
				return nil
			end,
			publishWildlife = function() end,
			bind = function() end,
			destroy = function() end,
		}
		local at = { value = 1000 }
		local clock = Clock.new(function()
			return at.value
		end)
		TamingExtension.configure(tamingPolicy :: any)
		local factory = assert(Factory(content, source, world, Memory.new(), clock, {
			sessionId = "services",
			leaseSeconds = 120,
			now = function()
				return math.floor(at.value)
			end,
			budget = {
				encode = function(value)
					return serde.encode("json", value)
				end,
			},
		}, provision, wildlifePolicy))
		TamingExtension.configure(nil)
		local services = factory.services
		assert(services.survivalWildlife, "wildlife port is published")
		local taming = false
		for _, extension in services.survivalExtensions or {} do
			taming = taming or extension.id == "taming"
		end
		assert(taming, "taming extension is built")
		local ok, err = pcall(
			Options.validate,
			{
				packConfig = { api = 1, order = { "survival-coop" }, configs = {} },
				contracts = { Contract },
				controls = {},
				storeName = "services",
				services = services,
			} :: any
		)
		assert(ok, "Options.validate rejected the real services: " .. tostring(err))
		assert(factory.close().ok, "release")
	end,
}
