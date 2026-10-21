--!strict
-- Native authority for market scenarios: production universe book and personal projection
-- over the harness atomic backend. Accounts are 30 days old with 10h played; player "3"
-- has not completed the tutorial. Fixture-only wallet seeds are persisted once.
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local Market = require("../../../../genres/survival-coop/module/CrossServerMarketExtension")
local Personal = require("../../../../core/infra/data/CrossServerMarketPersonal")
local Ports = require("../../../../games/robango-island/src/shared/MarketPorts")
local Content = require("../../../../core/domain/survival/Content")
local Contract = require("../../../../core/domain/genre/Contract")
local Session = require("../../../../core/infra/genre/Session")
local ProfileStore = require("../../../../core/infra/data/ProfileStore")

local COINS: { [string]: number } = { ["1"] = 100, ["2"] = 150, ["3"] = 50, ["4"] = 0 }
local SEED = "qa-market-seed"

local M = {}
-- Same participant projection and durable book as SurvivalFactory. The harness backend
-- substitutes atomic persistence; its advisory index is rebuilt by book recovery.
function M.market(content: any, backend: ProfileStore.Backend, now: () -> number, session: any, tutorial: any): any
	local personal = Personal.new(session, content.items, Ports.CATALOG_IDS)
	local ports = {
		update = function(key, transform)
			if string.sub(key, 1, 7) == "player:" then
				return personal.update(string.sub(key, 8), transform)
			end
			if string.sub(key, 1, 8) == "listing:" then
				local ok, reason = backend.update("qa-market-keys", function(keys)
					keys = keys or {}
					keys[key] = true
					return keys
				end)
				if not ok then
					return false, reason
				end
			end
			return backend.update("qa-market:" .. key, transform)
		end,
		index = function(partition, listing)
			local ok, reason = backend.update("qa-market-index:" .. partition, function(rows)
				rows = rows or {}
				rows[listing.id] = if listing.state == "ACTIVE" then listing else nil
				return rows
			end)
			assert(ok, reason)
		end,
		search = function(partition)
			local ok, rows = backend.update("qa-market-index:" .. partition, function(old)
				return old or {}
			end)
			assert(ok, rows)
			local result = {}
			for _, listing in rows do
				table.insert(result, listing)
			end
			table.sort(result, function(a, b)
				return a.id < b.id
			end)
			return result
		end,
		pending = function()
			local ok, keys = backend.update("qa-market-keys", function(old)
				return old or {}
			end)
			assert(ok, keys)
			local result = {}
			for key in keys do
				local loaded, listing = backend.update("qa-market:" .. key, function(old)
					return old
				end)
				assert(loaded, listing)
				if
					listing
					and listing.state ~= "SOLD"
					and listing.state ~= "RETURNED"
					and listing.state ~= "ABORTED"
				then
					table.insert(result, listing.id)
				end
			end
			table.sort(result)
			return result
		end,
	}
	local config = Ports.config({
		accountAgeDays = function()
			return 30
		end,
		sessionSeconds = function()
			return 10 * 3600
		end,
		tutorialComplete = tutorial,
	})
	return Market.new(ports, now, personal, Ports.CATALOG_IDS, config.account)
end
function M.new(packPath: string, backend: ProfileStore.Backend, now: () -> number)
	local content = assert(Content.canonicalize(serde.decode("yaml", fs.readFile(packPath .. "/content.yml"))))
	local session: Session.Session? = nil
	local extension = M.market(content, backend, now, {
		personalTransfer = function(actor)
			return if session then session.personalTransfer(actor) else nil
		end,
		personalTransaction = function(actor, transform)
			return assert(session, "fixture bound").personalTransaction(actor, transform)
		end,
	}, function(actor)
		return actor ~= "3"
	end)
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
	-- Participant state belongs to Session; book writes do not hold a second lease.
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
			return { ok = true }
		end,
	}
end
return M
