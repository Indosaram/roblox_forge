--!strict
-- Native authority only: the real MarketExtension over the harness backend with in-memory
-- wallets, a fixed bag and a recording item mover. Commands and assertions stay in qaharness.
local Market = require("../../../../genres/survival-coop/module/MarketExtension")
local Wallet = require("../../../../core/domain/economy/Wallet")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Contract = require("../../../../core/domain/genre/Contract")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")
local serde = require("@lune/serde")

local DAY = 86400
local M = {}
function M.new(backend: ProfileStore.Backend, now: () -> number)
	local wallets: { [string]: Wallet.Wallet } = {}
	Market.configure({
		catalogIds = { "wood", "stone" },
		account = function(actor, _now)
			return {
				id = actor,
				createdAt = -30 * DAY,
				playSeconds = 10 * 3600,
				tutorialComplete = actor ~= "3",
			}
		end,
		wallet = function(actor)
			wallets[actor] = wallets[actor] or Wallet.new({ coins = 1000 })
			return wallets[actor]
		end,
		item = function(actor, catalogId)
			return { itemId = "bag-" .. actor .. "-" .. catalogId, catalogId = catalogId, quantity = 20 }
		end,
		transfer = function(_request)
			return true, nil
		end,
		market = { throttle = { capacity = 100, refillPerSecond = 1 } },
	})
	local store = Fenced.new(backend, {
		sessionId = "qa-market",
		leaseSeconds = 120,
		now = now,
		budget = {
			encode = function(value: any): string
				return serde.encode("json", value)
			end,
		},
	})
	local extension = assert(Market.factory({
		store = function()
			return store
		end,
		now = now,
	}))
	-- The session port carries no `close`; the fixture owns the release instead.
	local port: any = {
		id = extension.id,
		handles = extension.handles,
		command = extension.command,
		snapshot = extension.snapshot,
	}
	return {
		services = { survivalExtensions = { port } },
		bind = function(_session: any) end,
		close = function(): Contract.Result
			return (extension :: any).close()
		end,
	}
end
return M
