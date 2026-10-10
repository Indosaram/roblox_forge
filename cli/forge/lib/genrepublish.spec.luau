--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Deadline = require("./deadline")
local publish = require("./genrepublish")
local project = require("./genreproject")
local publication = require("./packpublication")
local qa = require("../commands/qa")
local check = require("../commands/check")

return {
	["game publication preserves repeat bytes and authored metadata across generated changes"] = function()
		local root = project.absolute(
			(process.env.TEMP or "C:/Windows/Temp")
				.. "/forge-game-bytes-"
				.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		)
		assert(not fs.isDir(root), "fixture already exists")
		publish.ensureDir(root)
		local ok, reason = xpcall(function()
			local destination = root .. "/fixture"
			local function writeGame(text: string)
				local written, failure = publish.write({
					files = { ["game.yml"] = text },
					order = {},
					generation = {},
					legacy = false,
				}, destination, "fixture", { packsDir = root })
				assert(written, tostring(failure))
			end
			local generated =
				"# generated layout\nname: Fixture\nslug: fixture\nmonetization:\n  products:\n    - key: boost\n      price: 10\n"
			local longMetadata = string.rep("generated-metadata-", 40)
			generated ..= "description: " .. longMetadata .. "\n"
			writeGame(generated)
			assert(fs.readFile(destination .. "/game.yml") == generated, "fresh bytes changed")
			writeGame(generated)
			assert(fs.readFile(destination .. "/game.yml") == generated, "repeat bytes changed")
			local authored = string.gsub(
				generated,
				"      price: 10",
				"      price: 10\n      id: 123\n      custom: keep"
			) .. "user_metadata:\n  nested: [one, two]\n"
			fs.writeFile(destination .. "/game.yml", authored)
			fs.writeFile(destination .. "/user.txt", "exact authored bytes\r\n")
			writeGame(generated)
			assert(fs.readFile(destination .. "/game.yml") == authored, "authored no-op bytes changed")
			local changed = string.gsub(generated, "price: 10", "price: 20")
			writeGame(changed)
			local text = fs.readFile(destination .. "/game.yml")
			local game = serde.decode("yaml", text)
			assert(game.description == longMetadata, "long generated metadata changed")
			assert(game.monetization.products[1].price == 20, "generated change was lost")
			assert(game.monetization.products[1].id == 123, "published ID was lost")
			assert(game.monetization.products[1].custom == "keep", "entry metadata was lost")
			assert(game.user_metadata.nested[2] == "two", "unknown metadata was lost")
			writeGame(changed)
			assert(fs.readFile(destination .. "/game.yml") == text, "merged repeat bytes changed")
			assert(fs.readFile(destination .. "/user.txt") == "exact authored bytes\r\n", "authored file changed")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["pending publication rejects consumers regardless of journal contents"] = function()
		local root = project.absolute(
			(process.env.TEMP or "C:/Windows/Temp")
				.. "/forge-pending-"
				.. serde.hash("sha256", tostring(os.clock())):sub(1, 16)
		)
		assert(not fs.isDir(root), "fixture already exists")
		publish.ensureDir(root .. "/fixture.forge-stage")
		publish.ensureDir(root .. "/fixture")
		local ok, reason = xpcall(function()
			local destination = root .. "/fixture"
			fs.writeFile(destination .. "/game.yml", "name: Fixture\n")
			fs.writeFile(destination .. "/default.project.json", "{}")
			local registry = { root = root, order = {}, packages = {}, runtimes = {} }
			for _, marker in { "journal.tmp", "journal.json", "complete" } do
				fs.writeFile(destination .. ".forge-stage/" .. marker, "malformed")
				local pending = publication.pending(destination)
				assert(
					pending and string.find(pending, "FORGE_PUBLICATION_PENDING:", 1, true),
					'pending and string.find(pending, "FORGE_PUBLICATION_PENDING:", 1, true)'
				)
				local target, errors = qa.loadTarget("fixture", registry, { packsDir = root })
				assert(target == nil and errors[1] == pending, "native loader bypassed publication guard")
				assert(
					not qa.runScenario(
						{ "qa", "run", "--pack", "fixture", "--scenario", "missing", "--studio" },
						registry,
						{ packsDir = root }
					),
					'not qa.runScenario({ "qa", "run", "--pack", "fixture", "--scenario", "missing", "--studio" }, registry, { packsDir = ...'
				)
				assert(
					not check.run({ "check", "--project", destination .. "/default.project.json" }),
					'not check.run({ "check", "--project", destination .. "/default.project.json" })'
				)
			end
			fs.writeFile(destination .. ".forge-stage/user.txt", "unrelated")
			local recovered = publish.recover(destination)
			assert(not recovered, "unowned completed stage accepted")
			assert(fs.readFile(destination .. ".forge-stage/user.txt") == "unrelated", "unowned data removed")
			fs.writeFile(
				destination .. ".forge-backup",
				serde.encode("json", {
					api = 1,
					kind = "forge-publication-cleanup",
					destination = destination .. "-other",
				})
			)
			assert(not publish.recover(destination), "mismatched cleanup ownership accepted")
			assert(fs.readFile(destination .. ".forge-stage/user.txt") == "unrelated", "cleanup removed unowned data")
			fs.removeFile(destination .. ".forge-backup")
			fs.removeDir(destination .. ".forge-stage")
			assert(publication.pending(destination) == nil, "clean pack incorrectly rejected")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
	["publication and recovery termination matrix preserves committed revision"] = function()
		local cases = {}
		for _, event in
			{
				"owned",
				"backed-up",
				"journal-staged",
				"journal-installed",
				"complete-staged",
				"complete",
				"cleanup-marked",
				"cleanup-removed",
				"cleanup-finished",
			}
		do
			table.insert(cases, { event = event, index = 0, recovery = false })
		end
		for index = 1, 3 do
			table.insert(cases, { event = "replaced", index = index, recovery = false })
			table.insert(cases, { event = "restored", index = index, recovery = true })
			if index ~= 2 then
				table.insert(cases, { event = "restore-staged", index = index, recovery = true })
			end
		end
		for _, event in
			{ "recovery-complete-staged", "recovery-complete", "cleanup-marked", "cleanup-removed", "cleanup-finished" }
		do
			table.insert(cases, { event = event, index = 0, recovery = true })
		end
		for caseIndex, case in cases do
			local root = project.absolute(
				(process.env.TEMP or "C:/Windows/Temp")
					.. "/forge-publication-"
					.. serde.hash("sha256", tostring(os.clock()) .. tostring(caseIndex)):sub(1, 16)
			)
			assert(not fs.isDir(root), "fixture already exists")
			publish.ensureDir(root .. "/fixture")
			local child: process.ChildProcess? = nil
			local disarm: Deadline.Disarm? = nil
			local ok, reason = xpcall(function()
				local destination = root .. "/fixture"
				local modulePath = "./" .. project.relative(root, project.absolute("cli/forge/lib/genrepublish"))
				local priorGame = "name: Prior\nslug: fixture\n"
				fs.writeFile(destination .. "/game.yml", priorGame)
				fs.writeFile(destination .. "/a.txt", "prior\n")
				fs.writeFile(destination .. "/user.txt", "authored\n")
				local function scriptSource(recovering: boolean, event: string, index: number): string
					return string.format(
						[[
local p = require(%q)
local stdio = require("@lune/stdio")
-- Parent subscribes to READY before allowing any publication work.
stdio.write("READY\n")
stdio.readLine()
local function barrier(event, index)
 if event == %q and index == %d then
  stdio.write("BARRIER\n")
  stdio.readLine()
 end
end
local ok, reason
if %s then
 ok, reason = p.recover(%q, barrier)
else
 ok, reason = p.write({files={["a.txt"]="next\n",["b.txt"]="added\n",["game.yml"]="name: Next\nslug: fixture\n"},order={},generation={},legacy=false},%q,"fixture",{packsDir=%q},barrier)
end
assert(ok, reason)
]],
						modulePath,
						event,
						index,
						tostring(recovering),
						destination,
						destination,
						root
					)
				end
				local function terminate(source: string)
					local path = root .. "/child.luau"
					fs.writeFile(path, source)
					child = process.create("lune", { "run", path })
					local active = child :: process.ChildProcess
					local expired = false
					disarm = Deadline.arm(30, function()
						expired = true
						active:kill()
					end)
					local function receive(token: string)
						local output = ""
						while not string.find(output, token, 1, true) do
							local chunk = active.stdout:read()
							assert(chunk, "child exited before " .. token)
							output ..= chunk
						end
					end
					receive("READY\n")
					active.stdin:write("GO\n")
					receive("BARRIER\n")
					active:kill()
					assert(not active:status().ok and not expired, "intentional bounded termination")
					active.stdin:close()
					active.stdout:readToEnd()
					active.stderr:readToEnd()
					if disarm then
						disarm()
					end
					disarm = nil
					child = nil
				end
				if case.recovery then
					terminate(scriptSource(false, "replaced", 3))
				end
				terminate(scriptSource(case.recovery, case.event, case.index))
				assert(fs.isDir(destination), "destination disappeared")
				assert(
					(publication.pending(destination) ~= nil) == (case.event ~= "cleanup-finished"),
					"pending reader admission"
				)
				local committed = not case.recovery
					and table.find(
							{ "complete", "cleanup-marked", "cleanup-removed", "cleanup-finished" },
							case.event
						)
						~= nil
				local restart = root .. "/restart.luau"
				fs.writeFile(
					restart,
					string.format(
						"local p=require(%q)\nlocal ok,r=p.recover(%q)\nassert(ok,r)\n",
						modulePath,
						destination
					)
				)
				local result = process.exec("lune", { "run", restart })
				assert(result.ok, result.stdout .. result.stderr)
				assert(
					fs.readFile(destination .. "/a.txt") == (if committed then "next\n" else "prior\n"),
					'fs.readFile(destination .. "/a.txt") == (if committed then "next\\n" else "prior\\n")'
				)
				assert(fs.isFile(destination .. "/b.txt") == committed, "new-file rollback")
				local game = serde.decode("yaml", fs.readFile(destination .. "/game.yml"))
				assert(
					game.name == (if committed then "Next" else "Prior"),
					'game.name == (if committed then "Next" else "Prior")'
				)
				if not committed then
					assert(fs.readFile(destination .. "/game.yml") == priorGame, "exact rollback bytes")
				end
				assert(fs.readFile(destination .. "/user.txt") == "authored\n", "authored file changed")
				assert(publication.pending(destination) == nil, "restart left pending markers")
			end, debug.traceback)
			if disarm then
				disarm()
			end
			if child then
				child:kill()
				child:status()
			end
			fs.removeDir(root)
			assert(ok, case.event .. ":" .. tostring(case.index) .. ": " .. tostring(reason))
		end
	end,
}
