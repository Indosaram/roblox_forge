--!strict
-- Specs for `forge qa run --record` and `forge replay`: a recorded native run
-- replays to the same state hash, and a tampered journal does not.

local fs = require("@lune/fs")

local Journal = require("../../../core/domain/command/Journal")
local tempdir = require("../lib/tempdir")
local registryLib = require("../lib/genreregistry")
local qa = require("./qa")
local replay = require("./replay")

local function capture(): (any, { string }, { string })
	local out, err = {}, {}
	return {
		write = function(text: string)
			table.insert(out, text)
		end,
		ewrite = function(text: string)
			table.insert(err, text)
		end,
	},
		out,
		err
end

--- Records a real `qa run --record` of a native scenario on its fixture target.
local function withJournal(scenario: string, test: (string) -> ())
	local root = tempdir.path("forge-replay")
	local ok, reason = xpcall(function()
		fs.writeDir(root)
		local path = root .. "/journal.json"
		local registry = assert(registryLib.discover(nil))
		local passed = qa.runScenario({
			"qa",
			"run",
			"--pack",
			"fixture-survival",
			"--scenario",
			scenario,
			"--packs-root",
			"cli/forge/fixtures/" .. scenario,
			"--record",
			path,
		}, registry, nil)
		assert(passed, "recorded native run passes")
		test(path)
	end, debug.traceback)
	if fs.isDir(root) then
		fs.removeDir(root)
	end
	assert(ok, tostring(reason))
end

local function rewrite(path: string, mutate: (any) -> ())
	local journal = Journal.decode(fs.readFile(path))
	local copy = Journal.new(journal.meta)
	for index, entry in journal.entries do
		local clone = table.clone(entry)
		if entry.args then
			clone.args = table.clone(entry.args)
		end
		mutate({ index = index, entry = clone })
		copy:record(clone)
	end
	copy:finish(journal.stateHash :: string)
	fs.writeFile(path, Journal.encode(copy))
end

return {
	["a mutated fixture result replays to MISMATCH"] = function()
		local root = tempdir.path("forge-fixture-replay")
		local ok, reason = xpcall(function()
			fs.writeDir(root)
			local path = root .. "/journal.json"
			local registry = assert(registryLib.discover(nil))
			assert(
				qa.runScenario(
					{ "qa", "run", "--pack", "robango-island", "--scenario", "archipelago-chain", "--record", path },
					registry,
					nil
				)
			)
			local io = capture()
			assert(replay.run({ "replay", path }, io) == 0, "fixture journal MATCHes")
			local mutated = false
			rewrite(path, function(slot)
				if slot.entry.action == "fixture:archi_open" then
					slot.entry.args[2] = { ok = false, reason = "mutated-result" }
					mutated = true
				end
			end)
			assert(mutated, "fixture result changed")
			local mismatch, out, err = capture()
			assert(replay.run({ "replay", path }, mismatch) == 1, "result mutation exits MISMATCH")
			assert(string.find(table.concat(out), "replay: MISMATCH", 1, true))
			assert(string.find(table.concat(err), "result differs", 1, true))
		end, debug.traceback)
		if fs.isDir(root) then
			fs.removeDir(root)
		end
		assert(ok, tostring(reason))
	end,
	["a recorded native run replays to MATCH"] = function()
		withJournal("command-replay", function(path)
			local journal = Journal.decode(fs.readFile(path))
			assert(journal.meta.scenario == "survival-coop:command-replay", "scenario recorded")
			assert(journal.stateHash ~= nil, "final state hash recorded")
			local kinds: { [string]: number } = {}
			for _, entry in journal.entries do
				kinds[entry.kind] = (kinds[entry.kind] or 0) + 1
			end
			assert((kinds.join or 0) == 2 and (kinds.reload or 0) == 1, "join and reload journaled")
			assert((kinds.command or 0) >= 300 and (kinds.advance or 0) == 3, "commands and advances journaled")
			local io, out, err = capture()
			local code = replay.run({ "replay", path }, io)
			assert(code == 0, "MATCH exits 0: " .. table.concat(err, ""))
			assert(table.concat(out, "") == "replay: MATCH " .. (journal.stateHash :: string) .. "\n", out[1])
			local jsonIo, jsonOut = capture()
			assert(replay.run({ "replay", path, "--json" }, jsonIo) == 0, "json MATCH exits 0")
			assert(string.find(jsonOut[1], '"match":true', 1, true), jsonOut[1])
		end)
	end,
	["a tampered command arg replays to MISMATCH"] = function()
		withJournal("vitals-food-rest", function(path)
			local expected = assert(Journal.decode(fs.readFile(path)).stateHash, "recorded state hash")
			local io0 = capture()
			assert(replay.run({ "replay", path }, io0) == 0, "untampered vitals journal MATCHes")
			local tampered = false
			rewrite(path, function(slot)
				-- Rest at the reachable campfire becomes a rest at the unreachable one.
				if slot.entry.requestId == "near" and not tampered then
					slot.entry.args = { "far" }
					tampered = true
				end
			end)
			assert(tampered, "a command entry was tampered")
			local io, out = capture()
			assert(replay.run({ "replay", path }, io) == 1, "MISMATCH exits 1")
			local line = table.concat(out, "")
			assert(string.find(line, "replay: MISMATCH expected=" .. expected .. " actual=", 1, true), line)
			assert(not string.find(line, "actual=" .. expected .. "\n", 1, true), "actual differs")
		end)
	end,
	["a tampered clock replays to MISMATCH"] = function()
		withJournal("vitals-food-rest", function(path)
			rewrite(path, function(slot)
				if slot.entry.kind == "advance" and slot.entry.atMillis == 180000 then
					slot.entry.atMillis = 200000
				end
			end)
			local io, out = capture()
			assert(replay.run({ "replay", path }, io) == 1, "clock change is a MISMATCH")
			assert(string.find(out[1], "replay: MISMATCH", 1, true), out[1])
		end)
	end,
	["decode and usage errors return 2"] = function()
		withJournal("command-replay", function(path)
			fs.writeFile(path, (string.gsub(fs.readFile(path), '"atMillis":0', '"atMillis":7', 1)))
			local io, _, err = capture()
			assert(replay.run({ "replay", path }, io) == 2, "envelope hash mismatch is a decode error")
			assert(string.find(err[1], "hash mismatch", 1, true), err[1])
		end)
		local io = capture()
		assert(replay.run({ "replay" }, io) == 2, "missing path is usage")
		assert(replay.run({ "replay", "/nonexistent/journal.json" }, io) == 2, "unreadable path")
		assert(replay.run({ "replay", "a.json", "--bogus" }, io) == 2, "unknown flag")
	end,
}
