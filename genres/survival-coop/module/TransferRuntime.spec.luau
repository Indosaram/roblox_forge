--!strict
local process = require("@lune/process")
local run = require("../../../cli/forge/lib/run")
local serde = require("@lune/serde")
local Fixture = require("../../../cli/forge/fixtures/item-transfer-recovery/named-steps")
local Bridge = require("./TransferBridge")
local Session = require("../../../core/infra/genre/Session")
local Contract = require("./Contract")
local Memory = require("../../../core/infra/data/MemoryBackend")
local fs = require("@lune/fs")
local Runtime = require("./TransferRuntime")
local specs: { [string]: () -> () } = {}
specs["warehouse spatial authority applies only to new grants in both directions"] = function()
	for _, direction in { "deposit", "withdraw" } do
		local c = Fixture.context(direction)
		local port = c.tribe.transferStore()
		local authority = port.authority
		local reachable = false
		port.authority = function(...)
			return reachable and authority(...)
		end
		local runtime = Runtime.new({
			personal = c.personal,
			profile = function()
				return c.profile
			end,
			install = function(value)
				c.profile = value
			end,
			tribe = port,
			catalog = Fixture.catalog,
			now = function()
				return c.now
			end,
			maxReceipts = 4,
		})
		assert(
			runtime.command(c.request, 0, "server-proof", "client").error == "UNAUTHORIZED",
			'runtime.command(c.request, 0, "server-proof", "client").error == "UNAUTHORIZED"'
		)
		assert(
			next(c.snapshot()[Fixture.tribeKey].data.transferGrants.entries) == nil,
			"next(c.snapshot()[Fixture.tribeKey].data.transferGrants.entries) == nil"
		)
		Fixture.conserve(c, false)
		reachable = true
		assert(
			runtime.command(c.request, 0, "server-proof", "client").phase == "PREPARED",
			'runtime.command(c.request, 0, "server-proof", "client").phase == "PREPARED"'
		)
		reachable = false
		for _, phase in { "ESCROWED", "CREDITED", "FINALIZED" } do
			assert(runtime.recover(1)[1].phase == phase, "accepted transfer survives leaving warehouse")
		end
		assert(
			runtime.command(c.request, 0, "server-proof", "client").status == "confirmed",
			'runtime.command(c.request, 0, "server-proof", "client").status == "confirmed"'
		)
		Fixture.conserve(c, true)
	end
end
specs["recover reclaims expired finalized and cancelled grants within its budget"] = function()
	for _, direction in { "deposit", "withdraw" } do
		for _, cancelled in { false, true } do
			local c = Fixture.context(direction, nil, 0, 1)
			assert(c.command().phase == "PREPARED", "accepted preparation")
			if not cancelled then
				Fixture.finish(c)
			end
			c = Fixture.context(direction, c.snapshot(), 86400, 1)
			if cancelled then
				local results = c.runtime.recover(1)
				assert(#results == 1 and results[1].phase == "CANCELLED", "expiry cancels before retirement")
			end
			assert(c.tribe.epoch("owner") == 1, "new request horizon")
			local nextRequest = table.clone(c.request)
			nextRequest.id, nextRequest.outputId, nextRequest.epoch, nextRequest.expiresAt =
				"Transfer102", "next", "1", 172800
			assert(c.command(nextRequest).error == "RECEIPT_LIMIT", "retained record fills capacity")
			local results = c.runtime.recover(1)
			assert(#results == 1, "retirement shares one work budget")
			assert(
				next(c.snapshot()[Fixture.tribeKey].data.transferGrants.entries) == nil,
				"automatic expired grant retirement"
			)
			Fixture.conserve(c, not cancelled)
			assert(c.command().error == "REQUEST_EXPIRED", "retired request cannot remint")
			assert(c.command(nextRequest).phase == "PREPARED", "capacity reused without admin retirement")
		end
	end
end
specs["named durable boundaries restart immediately in both directions"] = function()
	local count = 0
	for _, direction in { "deposit", "withdraw" } do
		for _, boundary in
			{
				"GRANT_ACCEPTED",
				"SOURCE_PREPARED",
				"SOURCE_ESCROWED",
				"DESTINATION_COMMITTED",
				"SOURCE_FINALIZED",
				"SOURCE_FENCED",
				"DESTINATION_SOURCE_FINALIZED",
				"SOURCE_REMOVED",
				"DESTINATION_REMOVED",
				"GRANT_REMOVED",
			}
		do
			local cleanup = table.find({
				"SOURCE_FENCED",
				"DESTINATION_SOURCE_FINALIZED",
				"SOURCE_REMOVED",
				"DESTINATION_REMOVED",
				"GRANT_REMOVED",
			}, boundary) ~= nil
			for _, mode in { "failure", "lost", "crash" } do
				local c = Fixture.context(direction)
				if cleanup then
					c.command()
					Fixture.finish(c)
					c = Fixture.context(direction, c.snapshot(), 86400)
				end
				c.armed, c.mode, c.replay = boundary, mode, true
				for _ = 1, 8 do
					local ok, response = pcall(function()
						return if cleanup then c.runtime.recover(1) else c.command()
					end)
					if c.hits == 1 then
						if mode ~= "crash" then
							assert(ok, tostring(response))
							local result = if cleanup then response[1] else response
							assert(result and result.status ~= "confirmed", "failed ACK never confirms")
						else
							assert(
								not ok and string.find(tostring(response), "NAMED_CRASH", 1, true),
								"exact committed crash"
							)
						end
						break
					end
					assert(ok, tostring(response))
					Fixture.conserve(c, cleanup)
				end
				assert(c.hits == 1 and c.stopped, "exact named boundary hit once: " .. boundary)
				Fixture.conserve(c, cleanup)
				local result = run.exec("lune", {
					"run",
					"cli/forge/fixtures/item-transfer-recovery/named-steps",
					"restore-named",
					Fixture.encode({
						direction = direction,
						records = c.snapshot(),
						now = c.now,
						cleanup = cleanup,
						label = boundary .. "/" .. mode,
					}),
				})
				assert(result.ok and result.code == 0, result.stderr .. result.stdout)
				print(result.stdout)
				count += 1
			end
		end
	end
	assert(count == 60, "both directions and all named fault modes")
end
specs["resolver preserves accepted identity across rollover and serialized restart"] = function()
	for _, direction in { "deposit", "withdraw" } do
		local c = Fixture.context(direction)
		local input = {
			actor = "owner",
			epoch = 0,
			requestId = "public",
			direction = direction,
			itemId = "wood",
			quantity = 3,
			personalKey = Fixture.personalKey,
		}
		local original = assert(c.runtime.resolveRequest(input, 86400))
		c.request = original
		assert(c.command().phase == "PREPARED", "resolved request accepted")
		Fixture.finish(c)
		local terminal = c.command()
		local records = serde.decode("json", Fixture.encode(c.snapshot()))
		c = Fixture.context(direction, records, 86400)
		c.request = original
		assert(c.tribe.epoch("owner") == 1, "epoch rollover")
		for _, expiry in { 172800, 86400 } do
			local replay = assert(c.runtime.resolveRequest(input, expiry))
			assert(Fixture.encode(replay) == Fixture.encode(original), "immutable accepted request including expiry")
		end
		local replay = assert(c.runtime.resolveRequest(input, nil))
		local result = c.command(replay)
		assert(
			result.status == terminal.status
				and result.phase == terminal.phase
				and result.stateVersion == terminal.stateVersion,
			"original terminal replay"
		)
		for _, field in { "quantity", "itemId", "direction" } do
			local changed: any = table.clone(input)
			changed[field] = if field == "quantity"
				then 2
				elseif field == "itemId" then "other"
				elseif direction == "deposit" then "withdraw"
				else "deposit"
			local request, reason = c.runtime.resolveRequest(changed, 172800)
			assert(not request and reason == "TRANSFER_CONFLICT", "changed client fields cannot replay success")
		end
		Fixture.conserve(c, true)
		c.runtime.recover(1)
		local expired, reason = c.runtime.resolveRequest(input, 172800)
		assert(not expired and reason == "REQUEST_EXPIRED", "retired old epoch cannot recreate identity")
		Fixture.conserve(c, true)
	end
end
specs["recovery protects active pending escrow and bounds retirement fairly"] = function()
	for _, direction in { "deposit", "withdraw" } do
		local c = Fixture.context(direction)
		c.replay = true
		local stale = c.profile
		local staleEnvelope = serde.decode("json", Fixture.encode(stale.data.envelope))
		assert(c.command().phase == "PREPARED", "prepared")
		if direction == "deposit" then
			local current, reason = c.personal:commit(stale, stale.data.stateRevision, staleEnvelope, nil)
			assert(current and reason == "STALE_PERSONAL_REVISION", "same generation stale envelope refused")
		end
		local ok, reason = c.runtime.retire(c.request)
		assert(not ok and reason == "REQUEST_ACTIVE", "no early retirement")
		assert(c.runtime.recover(1)[1].phase == "ESCROWED", "active prepared advances not prunes")
		local old = c
		c = Fixture.context(direction, c.snapshot(), 86400)
		assert(old.command().status ~= "confirmed", "old owner fenced after takeover")
		local before = c.snapshot()
		local refused, pending = c.runtime.retire(c.request)
		assert(not refused and pending == "TRANSFER_PENDING", "expired escrow never cleaned")
		assert(
			c.snapshot()[c.request.source].data.itemTransfers.receipts[c.request.id].phase == "ESCROWED",
			"pending receipt retained"
		)
		assert(
			before[c.request.source].data.itemTransfers.receipts[c.request.id].phase == "ESCROWED",
			"durable source phase"
		)
		Fixture.finish(c)
		c.runtime.recover(1)
		Fixture.conserve(c, true)
		assert(
			next(c.snapshot()[Fixture.tribeKey].data.transferGrants.entries) == nil,
			"forward recovery then retirement"
		)
	end
	local c = Fixture.context("deposit")
	for index = 1, 2 do
		local request = table.clone(c.request)
		request.id, request.outputId, request.quantity = "fair" .. index, "output" .. index, 1
		for _ = 1, 4 do
			c.command(request)
		end
	end
	c = Fixture.context("deposit", c.snapshot(), 86400)
	assert(#c.runtime.recover(1) == 1, "one selected cleanup")
	local count = 0
	for _ in c.snapshot()[Fixture.tribeKey].data.transferGrants.entries do
		count += 1
	end
	assert(count == 1, "budget does not sweep all expired grants")
	assert(#c.runtime.recover(1) == 1, "next cursor cleanup")
	assert(next(c.snapshot()[Fixture.tribeKey].data.transferGrants.entries) == nil, "fair cursor retires next")
end
specs["grant acceptance remains irrevocable after membership revocation"] = function()
	for _, accepted in { false, true } do
		local c = Fixture.context("deposit")
		if accepted then
			c.command()
		end
		c.memory.update(Fixture.tribeKey, function(old: any)
			old.data.aggregate.settlement.roles.owner = nil
			old.data.aggregate.settlement.membershipRevision += 1
			return old
		end)
		if accepted then
			Fixture.finish(c)
		else
			assert(c.command().error == "UNAUTHORIZED", "revoke before acceptance refuses")
			Fixture.conserve(c, false)
		end
	end
end
specs["unavailable recovery discovery is visible and preserves durable pending work"] = function()
	for _, direction in { "deposit", "withdraw" } do
		for _, mode in { "failure", "lost", "lease" } do
			local c = Fixture.context(direction)
			assert(c.command().phase == "PREPARED", "durable pending transfer")
			local before = c.snapshot()
			if mode == "lease" then
				c.now = 30
			else
				c.discoveryFailure = mode
			end
			local results = c.runtime.recover(1)
			assert(#results == 1, "unavailable discovery must not look like no work")
			local result = results[1]
			assert(result.status == "recovering" and result.phase == "DISCOVERY", "explicit recovery status")
			assert(result.error == "TRANSFER_UNAVAILABLE", "unavailable owner code")
			assert(
				result.detail == (if mode == "lease" then "lease lost" else "DISCOVERY_ACK_FAILURE"),
				"cause retained"
			)
			assert(
				result.id == nil and result.source == nil and result.destination == nil,
				"no invented transfer capability"
			)
			local after = c.snapshot()
			for _, key in { Fixture.personalKey, Fixture.tribeKey } do
				assert(
					Fixture.encode(before[key].data.itemTransfers) == Fixture.encode(after[key].data.itemTransfers),
					"receipts unchanged"
				)
			end
			assert(
				Fixture.encode(before[Fixture.tribeKey].data.transferGrants.entries)
					== Fixture.encode(after[Fixture.tribeKey].data.transferGrants.entries),
				"no grant deletion or mint"
			)
			if mode ~= "lost" then
				assert(Fixture.encode(before) == Fixture.encode(after), "uncommitted discovery immutable")
			end
			if mode ~= "lease" then
				assert(c.discoveryHits == 1, "exact discovery fault")
			end
			Fixture.conserve(c, false)
			c = Fixture.context(direction, after, 60)
			Fixture.finish(c)
		end
	end
end
specs["Session scheduler success retains visible bridge unavailability"] = function()
	local bridge = Bridge.new({
		resolve = function()
			return nil
		end,
		epoch = function()
			return nil, "TRANSFER_UNAVAILABLE"
		end,
		request = function()
			error("unresolved owner cannot resolve request")
		end,
	})
	local config = serde.decode(
		"yaml",
		fs.readFile("cli/forge/fixtures/inventory-conservation/fixture-survival/econ.yml")
	).genre_contract
	local policy = {
		actions = { "survival-coop:transfer-deposit" },
		personal = {
			namespace = "unavailable",
			inventoryPath = { "genres", "survival-coop", "data", "inventory", "bag" },
		},
	}
	local session = Session.new(
		{
			packConfig = config,
			contracts = { Contract },
			controls = {},
			storeName = "UnavailableProof",
			durable = policy,
		},
		Memory.new(),
		{
			sessionId = "unavailable",
			lockTimeout = 120,
			retries = 0,
			now = function()
				return 0
			end,
		},
		{
			now = function()
				return 0
			end,
			roll = function()
				return 0
			end,
			emit = function() end,
			encode = Fixture.encode,
			survivalTransfer = bridge,
		},
		policy
	)
	assert(session.join("owner").ok, "actual Session joined")
	local before = Fixture.encode(session.envelope("owner"))
	local result = session.recoverTransfers("owner", 1)
	assert(result.ok and result.data and #result.data.results == 1, "ok means scheduler ran")
	local batch = result.data.results[1]
	assert(#batch == 1, "unavailable not empty no-work result")
	assert(
		batch[1].status == "recovering" and batch[1].phase == "DISCOVERY" and batch[1].error == "TRANSFER_UNAVAILABLE",
		"pending visible through Session"
	)
	assert(batch[1].id == nil and batch[1].source == nil and batch[1].destination == nil, "no invented identity")
	assert(Fixture.encode(session.envelope("owner")) == before, "unavailable recovery cannot mint")
	assert(session.close("owner").ok, "release actual Session")
end
if process.args[1] == "--run-recovery-unavailable" then
	specs["unavailable recovery discovery is visible and preserves durable pending work"]()
	specs["Session scheduler success retains visible bridge unavailability"]()
	print("PASS unavailable recovery discovery")
end
if process.args[1] == "--run-transfer-runtime" then
	local count = 0
	for name, test in specs do
		test()
		count += 1
		print("PASS " .. name)
	end
	print("transfer-runtime: " .. count .. " passed, 0 failed")
end
return specs
