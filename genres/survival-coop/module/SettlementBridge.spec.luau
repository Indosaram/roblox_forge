--!strict
local Bridge = require("./SettlementBridge")
local Runtime = require("./SettlementRuntime")
local Settlement = require("../../../core/domain/settlement/Settlement")
local Inventory = require("../../../core/domain/inventory/Inventory")
local Catalog = require("../../../core/domain/inventory/ItemCatalog")
local FencedStore = require("../../../core/infra/data/FencedStore")
local harness = require("../../../cli/forge/lib/qaharness")
local Shared = require("../../../core/domain/genre/Contract")
local function setup(replay: boolean?): (Bridge.Bridge, Runtime.Runtime, harness.Barrier)
	local gate = harness.barrier()
	local backend = {
		update = function(key: string, transform: (any) -> any): (boolean, any)
			if replay then
				gate.backend.update(key, function(old)
					transform(old)
					return old
				end)
			end
			return gate.backend.update(key, transform)
		end,
	}
	local runtime = assert(Runtime.new(
		{
			key = "tribe",
			now = function()
				return 0
			end,
			catalog = Catalog.new({}),
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
		},
		FencedStore.new(backend, {
			sessionId = "bridge",
			leaseSeconds = 120,
			now = function()
				return 0
			end,
		})
	))
	local bridge = Bridge.new({
		resolve = function(actor)
			return if actor == "owner" or actor == "member" then runtime else nil
		end,
		authorize = function(_, _, _, _)
			return { ok = true }
		end,
	})
	return bridge, runtime, gate
end
local function context(id: string): Shared.CommandContext
	return { actorId = "owner", requestId = id, sessionEpoch = 0 }
end
return {
	["backend callback replay cannot repeat external admission"] = function()
		local bridge = setup(true)
		assert(bridge.epoch("owner", "survival-coop:settlement-invite") == 0, "epoch")
		local charges = 0
		local result = bridge.command(
			"owner",
			"survival-coop:settlement-invite",
			{ "member", 0, 0 },
			context("one"),
			"client",
			function(): Shared.Result
				charges += 1
				return { ok = true }
			end
		)
		assert(result.ok and charges == 1, "one admission despite backend replay")
		assert(assert(bridge.snapshot("owner")).settlement.version == 1, "one mutation")
	end,
	["real owner replay skips admission and origin change conflicts"] = function()
		local bridge, runtime = setup()
		assert(bridge.epoch("owner", "survival-coop:settlement-invite") == 0, "tribe epoch")
		local charges = 0
		local admit = function(): Shared.Result
			charges += 1
			return { ok = true }
		end
		local args: { any } = { "member", 0, 0 }
		local action = "survival-coop:settlement-invite"
		assert(
			bridge.command("owner", action, args, context("one"), "client").reason == "ADMISSION_REQUIRED",
			"missing admission fails closed"
		)
		local result = bridge.command("owner", action, args, context("one"), "client", admit)
		assert(result.ok and charges == 1, "one admission")
		assert(
			bridge.command("owner", action, args, context("one"), "client", admit).ok and charges == 1,
			"replay no charge"
		)
		assert(
			bridge.command("owner", action, args, context("one"), "server", admit).reason == "REQUEST_CONFLICT"
				and charges == 1,
			"origin cannot replay"
		)
		assert(
			runtime.command("owner", "invite", args, context("one")).reason == "REQUEST_CONFLICT",
			"internal origin distinct"
		)
		local snapshot = assert(bridge.snapshot("owner"))
		assert(snapshot.settlement.roles.member == "member", "live sole owner snapshot")
		snapshot.settlement.roles.member = nil
		assert(assert(bridge.snapshot("owner")).settlement.roles.member == "member", "snapshot detached")
		assert(assert(bridge.link("owner"), "owner link").tribeId == "tribe", "link only")
	end,
	["authorization and exact allowlist fail before admission or mutation"] = function()
		local _, runtime = setup()
		local bridge = Bridge.new({
			resolve = function(_)
				return runtime
			end,
			authorize = function(_, _, _, _)
				return { ok = false, reason = "SPATIAL_REFUSED" }
			end,
		})
		local charges = 0
		local admit = function(): Shared.Result
			charges += 1
			return { ok = true }
		end
		assert(not bridge.handles("survival-coop:settlement-invite-extra"), "exact allowlist")
		assert(
			bridge.command(
				"owner",
				"survival-coop:settlement-invite",
				{ "member", 0, 0 },
				context("one"),
				"client",
				admit
			).reason == "SPATIAL_REFUSED",
			"trusted authorization"
		)
		assert(
			charges == 0 and assert(runtime.snapshot("owner")).settlement.roles.member == nil,
			"no mutation or debit"
		)
		local forged = context("forged")
		forged.actorId = "member"
		assert(
			bridge.command("owner", "survival-coop:settlement-invite", { "member", 0, 0 }, forged, "server", admit).reason
				== "FORBIDDEN",
			"authenticated actor binding"
		)
	end,
	["failed mutation retry and concurrent duplicate never charge admission twice"] = function()
		local bridge, _, gate = setup()
		assert(bridge.epoch("owner", "survival-coop:settlement-invite") == 0, "epoch")
		local charges = 0
		local admit = function(): Shared.Result
			charges += 1
			gate.fail(1)
			return { ok = true }
		end
		local action = "survival-coop:settlement-invite"
		local args: { any } = { "member", 0, 0 }
		assert(
			not bridge.command("owner", action, args, context("one"), "client", admit).ok,
			"commit fails after admission"
		)
		assert(
			bridge.command("owner", action, args, context("one"), "client", admit).ok and charges == 1,
			"retry retains admission"
		)
		local result: Shared.Result? = nil
		local suspend = function(): Shared.Result
			charges += 1
			gate.suspend()
			return { ok = true }
		end
		local worker = coroutine.create(function()
			result = bridge.command(
				"owner",
				"survival-coop:settlement-kick",
				{ "member", 1, 1 },
				context("two"),
				"client",
				suspend
			)
		end)
		local ok, signal = coroutine.resume(worker)
		assert(ok and signal == "commit-barrier-entered", "mutation parked after admission")
		assert(
			bridge.command(
				"owner",
				"survival-coop:settlement-kick",
				{ "member", 1, 1 },
				context("two"),
				"client",
				suspend
			).reason == "COMMAND_PENDING",
			"duplicate pending"
		)
		gate.resume()
		assert(coroutine.resume(worker))
		assert(
			coroutine.status(worker) == "dead" and result and result.ok and charges == 2,
			"only two logical admissions"
		)
	end,
}
