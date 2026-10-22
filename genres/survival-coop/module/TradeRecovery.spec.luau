--!strict
-- ui.direct-trade crash recovery and the ui.transaction read-only status query. A crash is
-- simulated after every durable settlement write: the server (and its in-memory trade) is
-- discarded, a fresh extension recovers from the escrow + receipt markers alone, and both
-- records must end consistent (all-or-nothing, nothing duplicated, nothing lost).
local TradeExtension = require("./DirectTradeExtension")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local Inventory = require("../../../core/domain/inventory/Inventory")
local serde = require("@lune/serde")

local catalog = Catalog.new({ { id = "plank", stackMax = 50, weightMilli = 0 } })

local function admit(): any
	return { ok = true }
end

-- Shared durable world: two personal records and a write budget (nil = unlimited).
local function world(): any
	local w: any = { records = {}, budget = nil, writes = 0 }
	local function record(balance: number, items: { any }): any
		local bag = Inventory.new("bag", { slots = 10, softWeightMilli = 90000, hardWeightMilli = 90000 })
		for _, item in items do
			bag = assert(Inventory.add(bag, catalog, item, bag.version))
		end
		return {
			data = {
				envelope = {
					genres = {
						["survival-coop"] = { data = { balance = balance, inventory = { bag = Inventory.save(bag) } } },
					},
				},
				itemTransfers = { version = 1, receipts = {} },
			},
		}
	end
	w.records.a = record(100, {
		{
			itemId = "p1",
			catalogId = "plank",
			quantity = 5,
			qualityMilli = 3000,
			durabilityMilli = 0,
			attributes = { level = 7 },
		},
	})
	w.records.b = record(40, {})
	-- One durable write; fails (crash) once the budget is spent.
	function w.apply(actor: string, transform: any): (boolean, string?)
		if w.budget and w.writes >= w.budget then
			return false, "CRASHED"
		end
		local current = w.records[actor].data
		local view = transform({
			envelope = serde.decode("json", serde.encode("json", current.envelope)),
			itemTransfers = serde.decode("json", serde.encode("json", current.itemTransfers)),
		})
		if serde.encode("json", view) ~= serde.encode("json", current) then
			w.writes += 1
		end
		w.records[actor] = { data = { envelope = view.envelope, itemTransfers = view.itemTransfers } }
		return true, nil
	end
	function w.data(actor: string): any
		return w.records[actor].data.envelope.genres["survival-coop"].data
	end
	-- A server: online actors get a live personal port; others only via transact.
	function w.server(online: { string }): any
		local function port(actor: string): any
			return {
				personal = {
					update = function(_self: any, _token: any, transform: any): (any?, string?)
						local ok, reason = w.apply(actor, transform)
						return if ok then w.records[actor] else nil, reason
					end,
				},
				profile = function(): any
					return w.records[actor]
				end,
				install = function() end,
			}
		end
		return TradeExtension.new({
			catalog = catalog,
			personal = function(actor: string): any
				return if table.find(online, actor) then port(actor) else nil
			end,
			transact = function(actor: string, transform: any): (boolean, any)
				return w.apply(actor, transform)
			end,
			members = function(): { string }
				return online
			end,
			now = function(): number
				return 1
			end,
		})
	end
	return w
end

local function sender(extension: any): (string, string, any) -> any
	local n = 0
	return function(actor: string, op: string, args: any): any
		n += 1
		return extension.command(
			actor,
			"survival-coop:" .. op,
			args,
			{ actorId = actor, requestId = "r" .. n, sessionEpoch = 1 },
			"client",
			admit
		)
	end
end

-- Negotiate a locked-ready trade: a gives 3 planks, b gives 30 coins; returns the id and
-- the final confirm (which settles).
local function negotiate(send: any): (string, () -> any)
	local id = send("a", "trade-open", { "b" }).data.tradeId
	assert(send("a", "trade-offer", { id, { revision = 0, itemId = "p1", quantity = 3, coins = 0 } }).ok, "offer a")
	assert(send("b", "trade-offer", { id, { revision = 1, coins = 30 } }).ok, "offer b")
	assert(send("a", "trade-confirm", { id, 2 }).ok, "a confirms")
	return id, function(): any
		return send("b", "trade-confirm", { id, 2 })
	end
end

local function planks(w: any, actor: string): number
	local total = 0
	for _, item in w.data(actor).inventory.bag.items do
		total += item.quantity
	end
	return total
end

-- Both sides consistent: conserved totals and either nothing moved or everything moved.
local function consistent(w: any, label: string): string
	local coinsA, coinsB = w.data("a").balance, w.data("b").balance
	local planksA, planksB = planks(w, "a"), planks(w, "b")
	assert(coinsA + coinsB == 140, label .. ": coins conserved " .. coinsA .. "+" .. coinsB)
	assert(planksA + planksB == 5, label .. ": items conserved " .. planksA .. "+" .. planksB)
	if coinsA == 130 and coinsB == 10 and planksA == 2 and planksB == 3 then
		for _, item in w.data("b").inventory.bag.items do
			assert(item.attributes.level == 7 and item.qualityMilli == 3000, label .. ": exact stack delivered")
		end
		return "settled"
	end
	assert(coinsA == 100 and coinsB == 40 and planksA == 5 and planksB == 0, label .. ": half-settled")
	return "rolled-back"
end

local cases: { [string]: () -> () } = {}

cases["a crash after every settlement write recovers both sides consistently"] = function()
	local outcomes = {}
	for crashAfter = 0, 6 do
		for _, order in { { "a", "b" }, { "b", "a" }, { "a" } } do
			local w = world()
			local send = sender(w.server({ "a", "b" }))
			local _, finish = negotiate(send)
			w.budget = crashAfter
			finish()
			-- The crashed server is gone; a fresh one sees only the durable records.
			w.budget = nil
			local label = "crash after " .. crashAfter .. " writes, join " .. table.concat(order, ",")
			local fresh = w.server(order)
			for _, actor in order do
				local recovered = fresh.recover(actor, 8)
				assert(recovered.pending == 0, label .. ": recovery finished")
			end
			local outcome = consistent(w, label)
			-- Writes before B's debit roll back; from B's debit on they roll forward.
			assert(outcome == (if crashAfter <= 1 then "rolled-back" else "settled"), label .. " -> " .. outcome)
			-- The other side joining later only finishes bookkeeping; then nothing writes again.
			local later = w.server({ "a", "b" })
			later.recover("a", 8)
			later.recover("b", 8)
			assert(consistent(w, label .. " both joined") == outcome, label .. ": same outcome after both join")
			local writes = w.writes
			for _, actor in { "a", "b" } do
				fresh.recover(actor, 8)
				w.server({ "a", "b" }).recover(actor, 8)
			end
			assert(w.writes == writes and consistent(w, label .. " replay") == outcome, label .. ": idempotent")
			outcomes[outcome] = true
		end
	end
	assert(outcomes.settled and outcomes["rolled-back"], "both recovery directions exercised")
end

cases["operation-status reports settlement state read-only and refuses unknown ids"] = function()
	local w = world()
	local extension = w.server({ "a", "b" })
	local send = sender(extension)
	local unknown = send("a", "operation-status", { "nope" })
	assert(not unknown.ok and unknown.reason == "UNKNOWN_OPERATION", "unknown operationId refused")
	local id, finish = negotiate(send)
	assert(send("a", "operation-status", { id }).data.status == "verifying", "open trade is verifying")
	w.budget = w.writes + 1
	local stuck = finish()
	assert(stuck.data and stuck.data.status == "recovering" and stuck.data.operationId == id, "pending surfaced")
	local before = serde.encode("json", w.records)
	local status = send("b", "operation-status", { id })
	assert(status.ok and status.data.status == "settling" and status.data.operationId == id, "settling")
	assert(serde.encode("json", w.records) == before, "status query never writes or re-debits")
	w.budget = nil
	-- A different server only has the durable markers.
	local other = sender(w.server({ "a", "b" }))
	assert(other("a", "operation-status", { id }).data.status == "settling", "markers say settling")
	assert(extension.recover("a", 8).pending == 0, "recovered")
	assert(other("b", "operation-status", { id }).data.status == "delivered", "credit marker says delivered")
	assert(send("a", "operation-status", { id }).data.status == "delivered", "live record says delivered")
	-- A rolled-back trade reads rejected; a committed durable command reads by requestId.
	local w2 = world()
	local send2 = sender(w2.server({ "a", "b" }))
	local id2, finish2 = negotiate(send2)
	w2.data("b").balance = 0
	assert(not finish2().ok, "b cannot pay")
	local fresh2 = sender(w2.server({ "a", "b" }))
	assert(fresh2("a", "operation-status", { id2 }).data.status == "rejected", "refunded trade rejected")
	w2.records.a.data.envelope.commands = {
		epochs = { ["1"] = { outcomes = { req9 = { result = { ok = false, reason = "INSUFFICIENT_FUNDS" } } } } },
	}
	local ledger = fresh2("a", "operation-status", { "req9" })
	assert(ledger.data.status == "rejected" and ledger.data.reason == "INSUFFICIENT_FUNDS", "ledger outcome")
	assert(fresh2("b", "operation-status", { "req9" }).reason == "UNKNOWN_OPERATION", "another actor's id unknown")
end

return cases
