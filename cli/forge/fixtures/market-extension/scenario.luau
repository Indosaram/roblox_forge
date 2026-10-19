--!strict
-- Native authority for the market-trade scenario: the real MarketExtension (durable escrow over
-- the Session's personal aggregates) configured with the pack's own tradeable goods, over the
-- harness backend. Players facts are fixed here: every account is 30 days old with 10h played;
-- player "3" has not finished the tutorial. The pack starts every wallet at 0 Coins and has no
-- coin faucet yet, so this fixture (test authority only) seeds each joining player's persisted
-- Coins balance once from `COINS`, through the same atomic personal write the market uses.
-- Commands and assertions stay in qaharness.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Market = require("../../../../genres/survival-coop/module/MarketExtension")
local Ports = require("../../../../games/robango-island/src/shared/MarketPorts")
local Content = require("../../../../core/domain/survival/Content")
local Fenced = require("../../../../core/infra/data/FencedStore")
local Contract = require("../../../../core/domain/genre/Contract")
local Session = require("../../../../core/infra/genre/Session")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")

local COINS: { [string]: number } = { ["1"] = 100, ["2"] = 150, ["3"] = 50, ["4"] = 0 }
local SEED = "qa-market-seed"

local M = {}
function M.new(packPath: string, backend: ProfileStore.Backend, now: () -> number)
	local content = assert(Content.canonicalize(serde.decode("yaml", fs.readFile(packPath .. "/content.yml"))))
	local session: Session.Session? = nil
	Market.configure(Ports.config({
		accountAgeDays = function(_actor)
			return 30
		end,
		sessionSeconds = function(_actor, _now)
			return 10 * 3600
		end,
		tutorialComplete = function(actor)
			return actor ~= "3"
		end,
	}))
	local store = Fenced.new(backend, {
		sessionId = "qa-market",
		leaseSeconds = 120,
		now = function()
			return math.floor(now())
		end,
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
		now = function()
			return math.floor(now())
		end,
		content = content,
		personalTransfer = function(actor)
			return if session then session.personalTransfer(actor) else nil
		end,
		members = function()
			return if session then session.members() else {}
		end,
	}))
	local function seed(actor: string)
		local amount = COINS[actor]
		local port = if session then session.personalTransfer(actor) else nil
		if amount == nil or port == nil then
			return
		end
		local token = assert(port.personal:update(port.profile(), function(view)
			if view.itemTransfers.receipts[SEED] == nil then
				view.envelope.genres["survival-coop"].data.balance = amount
				view.itemTransfers.receipts[SEED] = { phase = "QA" }
			end
			return view
		end))
		port.install(token)
	end
	-- The session port carries no `close`; the fixture owns the release instead.
	local port: any = table.clone(extension)
	port.close = nil
	return {
		services = { survivalExtensions = { port } },
		bind = function(value: Session.Session)
			session = value
			local join = value.join
			value.join = function(actor)
				local result = join(actor)
				if result.ok then
					seed(actor)
				end
				return result
			end
		end,
		close = function(): Contract.Result
			local closed = (extension :: any).close()
			Market.configure(nil)
			return closed
		end,
	}
end
return M
