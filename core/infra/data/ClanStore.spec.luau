--!strict
local Store = require("./ClanStore")
local Wallet = require("./ClanStoreWallet")
local Clan = require("../../domain/settlement/Clan")
local Data = require("../../domain/genre/SerializedData")
local serde = require("@lune/serde")

local function fixture(): any
	local persisted: any = nil
	local service: any = { failBefore = false, failAfter = false, replay = true }
	function service:UpdateAsync(_key: string, transform: any): any
		if self.failBefore then
			self.failBefore = false
			error("THROTTLED")
		end
		if self.replay then
			transform(Data.clone(persisted))
		end
		local candidate = transform(Data.clone(persisted))
		persisted = Data.clone(candidate)
		if self.failAfter then
			self.failAfter = false
			error("ACK_LOST")
		end
		return Data.clone(persisted)
	end
	local now = 0
	local function build(session: string): any
		return Store.new({
			dataStore = service,
			rules = { maxMembers = 50 },
			maxBytes = 4000000,
			memoryMap = {
				SetAsync = function()
					error("MEMORYSTORE_THROTTLED")
				end,
			},
			messaging = {
				PublishAsync = function()
					error("MESSAGING_UNAVAILABLE")
				end,
			},
			cacheSeconds = 30,
			topic = "clans",
			encode = function(value: any): string
				return serde.encode("json", value)
			end,
			fence = {
				sessionId = session,
				leaseSeconds = 10,
				now = function(): number
					return now
				end,
			},
		})
	end
	return {
		service = service,
		build = build,
		clock = function(value: number)
			now = value
		end,
	}
end

return {
	["create commits an unleased clan record and retries without duplicate membership"] = function()
		local f = fixture()
		local directory = f.build("create")
		assert(directory.create("owner", "alpha").ok, "create")
		assert(directory.create("owner", "alpha").ok, "idempotent owner retry")
		assert(not directory.create("owner", "beta").ok, "one membership per actor")
		assert(not directory.create("other", "alpha").ok, "unique clan id")
		local token = directory.store:acquire("clan:alpha", function(data)
			return data
		end)
		assert(token and token.data.owner == "owner", "new aggregate is a valid fenced record")
	end,
	["browse pages every live clan with member count, capacity and recruiting state"] = function()
		local f = fixture()
		local directory = f.build("browse")
		for index = 1, 9 do
			assert(directory.create("owner" .. index, "tide" .. index).ok, "create")
		end
		assert(directory.create("solo", "reef").ok, "create reef")
		local first = assert(directory.browse("", 1, 8))
		assert(first.total == 10 and first.pages == 2 and #first.rows == 8, "first page")
		assert(first.rows[1].id == "reef" and first.rows[1].members == 1 and first.rows[1].capacity == 50, "row")
		assert(first.rows[1].recruiting, "open clan recruits")
		local last = assert(directory.browse("", 99, 8))
		assert(last.page == 2 and #last.rows == 2 and last.rows[2].id == "tide9", "page clamps to the last")
		local found = assert(directory.browse("TIDE", 1, 8))
		assert(found.total == 9 and found.rows[1].id == "tide1", "case-insensitive name search")
		local token = assert(directory.store:acquire("clan:reef", function(data: any): any
			return data
		end))
		assert(directory.store:update(token, function(data: any): any
			for index = 1, 49 do
				data.members["m" .. index] = { role = "member", withdraw = false }
			end
			return data
		end))
		local full = assert(directory.browse("reef", 1, 8)).rows[1]
		assert(full.members == 50 and not full.recruiting, "a full clan is not recruiting")
		assert(directory.store:update(token, function(data: any): any
			data.members = { solo = data.members.solo }
			data.dissolved = true
			return data
		end))
		assert(assert(directory.browse("reef", 1, 8)).total == 0, "dissolved clans drop out")
	end,
	["directory CAS owns membership uniqueness, cap, dissolution and stale fences"] = function()
		local f = fixture()
		local a, b = f.build("a"), f.build("b")
		local token = assert(
			a.store:acquire("clan:alpha", function(): any
				return Clan.new("alpha", "owner")
			end),
			"create alpha"
		)
		assert(a.membership("owner") == "alpha", "owner index installed")
		local duplicate = b.store:acquire("clan:beta", function(): any
			return Clan.new("beta", "owner")
		end)
		assert(duplicate == nil, "cross-clan duplicate rejected inside CAS")
		local full = a.store:update(token, function(data: any): any
			for index = 1, 50 do
				data.members[tostring(index)] = { role = "member", withdraw = false }
			end
			return data
		end)
		assert(full == nil and a.membership("1") == nil, "51 member candidate cannot publish")
		f.clock(11)
		local newer = assert(
			b.store:acquire("clan:alpha", function(data: any): any
				return data
			end),
			"new fence acquired"
		)
		assert(a.store:update(token, function(data: any): any
			data.funds = 999
			return data
		end) == nil, "stale generation cannot publish")
		assert(
			b.store:update(newer, function(data: any): any
				data.dissolved = true
				return data
			end),
			"dissolution committed"
		)
		assert(b.membership("owner") == nil, "dissolution clears authoritative index")
	end,
	["wallet escrow survives replay and ambiguous debit ACK without minting"] = function()
		local f = fixture()
		local d = f.build("a")
		local source = assert(
			d.store:acquire("personal:owner", function(): any
				return { balance = 100 }
			end),
			"personal source opened"
		)
		local target = assert(
			d.store:acquire("clan:alpha", function(): any
				return Clan.new("alpha", "owner")
			end),
			"clan destination opened"
		)
		local config = {
			store = d.store,
			maxReceipts = 100,
			now = function(): number
				return 0
			end,
			encode = function(value: any): string
				return value.id .. ":" .. value.operation .. ":" .. value.amount
			end,
			authorize = function(): boolean
				return true
			end,
			balance = function(data: any, key: string): number
				return if string.sub(key, 1, 5) == "clan:" then data.funds else data.balance
			end,
			setBalance = function(data: any, key: string, balance: number)
				if string.sub(key, 1, 5) == "clan:" then
					data.funds = balance
				else
					data.balance = balance
				end
			end,
		}
		local request = {
			id = "r",
			actor = "owner",
			epoch = "e",
			expiresAt = 100,
			source = source.key,
			destination = target.key,
			amount = 30,
			operation = "deposit",
		}
		f.service.failAfter = true
		assert(Wallet.advance(config, source, target, request).status == "recovering", "lost ACK is not confirmation")
		local result = Wallet.advance(config, source, target, request)
		assert(
			result.status == "confirmed" and result.source.data.balance == 70 and result.destination.data.funds == 30,
			"replay credits one debit"
		)
		result = Wallet.advance(config, result.source, result.destination, request)
		assert(
			result.status == "confirmed" and result.source.data.balance + result.destination.data.funds == 100,
			"final replay conserves currency"
		)
		request.amount = 31
		assert(
			Wallet.advance(config, result.source, result.destination, request).reason == "TRANSFER_CONFLICT",
			"receipt binding rejects changed amount"
		)
		request.id, request.amount, request.operation = "w", 1, "withdraw"
		request.source, request.destination = target.key, source.key
		assert(
			Wallet.advance(config, result.destination, result.source, request).reason == "FORBIDDEN",
			"owner has no implicit withdrawal grant"
		)
		f.service.failBefore = true
		local id, err = d.membership("owner")
		assert(id == nil and err ~= nil, "service failure is not absence")
	end,
}
