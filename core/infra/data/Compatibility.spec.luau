--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Deadline = require("../../../cli/forge/lib/deadline")
local Profile = require("./ProfileStore")
local Schema = require("../../domain/state/ProfileSchema")
local fixture = "core/infra/data/fixtures/profile-legacy.json"

return {
	["serialized legacy lock and future payload survive refused upgrade"] = function()
		local record = serde.decode("json", fs.readFile(fixture))
		local before = serde.encode("json", record)
		local store = Profile.new({
			update = function(_key, transform)
				record = transform(record)
				return true, record
			end,
		}, {
			sessionId = "new",
			lockTimeout = 30,
			retries = 0,
			now = function()
				return 30
			end,
		})
		local loaded, err = store:load("legacy", function()
			error("active legacy lease cannot migrate")
		end)
		assert(not loaded and err == "locked" and serde.encode("json", record) == before, "lease preserved")
		record.lock = nil
		record.data.version = 2
		before = serde.encode("json", record)
		assert(not pcall(store.load, store, "legacy", function(raw)
			return Schema.migrate(raw, 1, function()
				return {}
			end, {})
		end), "future payload fails before upgrade commit")
		assert(serde.encode("json", record) == before, "no reset downgrade or lock acquisition")
	end,
	["terminated processes recover serialized upgrade escrow credit and finalization"] = function()
		for _, barrier in { "ESCROWED", "CREDITED", "FINALIZED" } do
			local directory = (process.env.TEMP or "/tmp")
				.. "/forge-save-compat-"
				.. serde.hash("sha256", tostring(os.clock()) .. barrier):sub(1, 16)
			assert(not fs.isDir(directory), "owned fixture already exists")
			fs.writeDir(directory)
			local child: process.ChildProcess? = nil
			local disarm: Deadline.Disarm? = nil
			local ok, reason = xpcall(function()
				local path = directory .. "/records.json"
				fs.writeFile(path, serde.encode("json", { legacy = serde.decode("json", fs.readFile(fixture)) }))
				for _, mode in { "produce", "replay" } do
					child = process.create("lune", {
						"run",
						"core/infra/data/fixtures/compatibility-process",
						path,
						mode,
						barrier,
					})
					local active = child :: process.ChildProcess
					local expired = false
					disarm = Deadline.arm(30, function()
						expired = true
						active:kill()
					end)
					local expected = if mode == "produce" then "COMMITTED:" .. barrier .. "\n" else "REPLAY_OK\n"
					local signal = ""
					while not string.find(signal, expected, 1, true) do
						local chunk = active.stdout:read()
						assert(chunk, "process exited before " .. expected .. signal)
						signal ..= chunk
					end
					if mode == "produce" then
						active:kill()
					end
					local status = active:status()
					assert(not expired and status.ok == (mode == "replay"), "bounded crash or successful restart")
					active.stdin:close()
					active.stdout:readToEnd()
					active.stderr:readToEnd()
					if disarm then
						disarm()
					end
					disarm, child = nil, nil
					local records = serde.decode("json", fs.readFile(path))
					assert(records.legacy.version == 1 and records.legacy.data.version == 1, "legacy upgrade persisted")
					assert(
						records.legacy.data.coins == 27 and records.legacy.lock == nil,
						"currency and release preserved"
					)
					if mode == "produce" then
						local owner = if barrier == "CREDITED" then records.destination else records.source
						assert(owner.data.itemTransfers.receipts.Transfer101.phase == barrier, "exact durable barrier")
						assert(
							owner.lease.sessionId == "producer" and owner.lease.expiresAt == 51,
							"crash retains lease"
						)
					else
						assert(
							records.source.lease == nil and records.destination.lease == nil,
							"restart releases leases"
						)
					end
				end
			end, debug.traceback)
			if disarm then
				disarm()
			end
			if child then
				child:kill()
				child:status()
				child.stdin:close()
				child.stdout:readToEnd()
				child.stderr:readToEnd()
			end
			if ok then
				fs.removeDir(directory)
			end
			assert(ok, tostring(reason) .. "; retained failure fixture: " .. directory)
		end
	end,
}
