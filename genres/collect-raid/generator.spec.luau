--!strict
local Generator = require("./generator")
local Package = require("../../cli/forge/lib/genrecontract")
local Planner = require("./generation/planner")
local Scaffold = require("./generation/scaffold")
local Executor = require("../../core/domain/genre/Executor")
local Loop = require("./module/runtime/Loop")
local luau = require("@lune/luau")
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local input: Package.GenerateInput = {
	mode = "plan",
	slug = "collect-proof",
	pascal = "CollectProof",
	title = "",
	concept = "volcano egg keepers",
	seed = 7,
	teams = { "Red Team", 'Blue"Team' },
	debugName = "CollectProofDebug",
	guiName = "CollectProofGui",
}
local function files(generated: Package.Generated): { [string]: string }
	local result = {}
	for _, artifact in generated.artifacts do
		result[artifact.path] = artifact.content
	end
	return result
end
return {
	["extracted starter bytes equal original scaffold and strict wrapper delegates"] = function()
		-- Original 66dd6e934e6d31252e19aa1a32fd944574c2281d:cli/forge/lib/scaffold.luau.
		-- Git blob ae633cef5e1525da65d9202007b0f89e906b14b2, not a current generator snapshot.
		local source = fs.readFile("genres/collect-raid/fixtures/scaffold-66dd6e9.unit")
		assert(
			serde.hash("sha256", source) == "ab9854d793d0bc316ab0d518e59a2a35a69790086835a53b88faef74fa0428e8",
			"historical scaffold bytes changed"
		)
		local old = luau.load(source, {
			environment = {
				require = function(path)
					assert(path == "./assets", "original scaffold dependency")
					return require("../../cli/forge/lib/assets")
				end,
			},
		})()
		local original = old.collectRaidFiles("collect-proof", "CollectProof")
		local extracted = Scaffold.collectRaidFiles("collect-proof", "CollectProof")
		-- The starter has moved from the extraction baseline in exactly one place:
		-- the client's safe-area wrapper. The design requires safe area by
		-- construction (ScreenInsets CoreUISafeInsets plus one SafeArea frame), and
		-- the sweep `hud` column reads the scaffolded client as collect-raid's HUD
		-- owner, so the guarantee has to be in these bytes rather than in the genre
		-- runtime Hud the scaffold does not bind. Every other starter path is still
		-- byte-identical to the extraction and no path was added or removed, so any
		-- further drift fails here and must be argued for rather than absorbed.
		local drifted: { string } = {}
		for path, content in original do
			if extracted[path] ~= content then
				table.insert(drifted, path)
			end
		end
		table.sort(drifted)
		-- The starter has moved from the extraction baseline in exactly three places: the client's
		-- safe-area wrapper (see below), the server's ForgeQA surface, and the starter loop. The
		-- generated pack's own server is the playable runtime, so the QA surface is bound to THAT
		-- runtime - the real hatch, the real leaderstats balance and the real profile - rather than to
		-- a second, parallel contract runtime beside it. The loop rules moved out of the server into
		-- the pure src/shared/StarterLoop.luau so the generated smoke/smoke.luau drives the same
		-- code under Lune (`forge smoke --strict` had no smoke to run), and Config.teamColors became
		-- BrickColor names so Config loads under Lune. Every other starter path is byte-identical to
		-- the extraction and only those three paths were added, so any further drift fails here.
		assert(
			#drifted == 3
				and drifted[1] == "src/client/CollectProofClient.client.luau"
				and drifted[2] == "src/server/CollectProofServer.server.luau"
				and drifted[3] == "src/shared/Config.luau",
			"starter bytes changed outside the intended client wrapper, server QA surface and loop: "
				.. table.concat(drifted, ", ")
		)
		local added: { [string]: boolean } = {
			["smoke/smoke.luau"] = true,
			["smoke/smoke.spec.luau"] = true,
			["src/shared/StarterLoop.luau"] = true,
		}
		for path in extracted do
			assert(original[path] ~= nil or added[path], "extra starter path: " .. path)
		end
		for path in added do
			assert(extracted[path] ~= nil, "starter loop path missing: " .. path)
		end
		local config = extracted["src/shared/Config.luau"]
		assert(string.find(config, "BrickColor.new", 1, true) == nil, "Config must stay engine-free plain data")
		assert(string.find(config, 'Red = "Really red"', 1, true) ~= nil, "Config team colors are BrickColor names")
		-- The intended move is pinned, so it can be neither widened nor silently
		-- reverted: the client's new bytes are frozen by hash and must carry the
		-- guarantees the design requires. The baseline advanced three times, each for a
		-- defect a live capture exposed: the safe-area wrapper; the hint label's own
		-- Name (two sibling labels both called "Label" share one path, and the QA driver
		-- addresses a control by its exact path); and the panel's live chat reservation.
		local client = extracted["src/client/CollectProofClient.client.luau"]
		assert(
			serde.hash("sha256", client) == "e4146ee1c07a6ef3512717cad5914868688d0b6d5025c1c5f10366198deefe4b",
			"scaffolded client bytes changed"
		)
		assert(string.find(client, "CoreUISafeInsets", 1, true) ~= nil, "client safe-area inset missing")
		assert(string.find(client, "SafeArea", 1, true) ~= nil, "client SafeArea frame missing")
		-- Distinct control paths: the two labels under the Hud panel must not share a name.
		assert(string.find(client, 'hint.Name = "Hint"', 1, true) ~= nil, "client hint label shares the default name")
		-- The panel must reserve the chat window's footprint instead of sitting on it, with a
		-- documented floor that clears the chat even before the chat can be measured.
		assert(string.find(client, 'FindFirstChild("Chat")', 1, true) ~= nil, "client does not reserve the chat region")
		assert(string.find(client, "PHONE_CHAT_FLOOR", 1, true) ~= nil, "client chat reservation has no floor")
		-- The server drift is pinned too, and it must carry the real-runtime QA surface the review
		-- requires: a ForgeQA folder whose dispatch drives the pack's own hatch, whose snapshot reads
		-- the real leaderstats balance, and whose save writes the real profile.
		local server = extracted["src/server/CollectProofServer.server.luau"]
		assert(
			serde.hash("sha256", server) == "d6dc495a796391e3b37b43f4a3af8e257e7af0f25f52e7a6beb2168618f94a1b",
			"scaffolded server bytes changed"
		)
		-- The standard surface is published by the pack's own server and backed by the real runtime:
		-- the remotes the QA driver reads, and a ForgeQA folder whose dispatch drives the real hatch.
		assert(
			string.find(server, 'ForgeAction.Name = "ForgeAction"', 1, true) ~= nil
				and string.find(server, 'ForgeState.Name = "ForgeState"', 1, true) ~= nil,
			"scaffolded server publishes no ForgeState/ForgeAction surface"
		)
		assert(
			string.find(server, "ForgeAction.OnServerInvoke", 1, true) ~= nil
				and string.find(server, "hatch(player.Team.Name, player)", 1, true) ~= nil,
			"scaffolded ForgeAction does not dispatch the real hatch"
		)
		assert(string.find(server, "ForgeQA", 1, true) ~= nil, "scaffolded server binds no ForgeQA surface")
		assert(
			string.find(server, 'bind("dispatch"', 1, true) ~= nil and string.find(server, "hatch(", 1, true) ~= nil,
			"scaffolded ForgeQA dispatch does not drive the real hatch"
		)
		assert(
			string.find(server, 'bind("snapshot"', 1, true) ~= nil
				and string.find(server, "session.coins.Value", 1, true) ~= nil,
			"scaffolded ForgeQA snapshot does not read the real balance"
		)
		assert(
			string.find(server, 'bind("save"', 1, true) ~= nil
				and string.find(server, "store:save(session.profile)", 1, true) ~= nil,
			"scaffolded ForgeQA save does not write the real profile"
		)
		assert(
			string.find(server, 'prompt.Name = "Hatch"', 1, true) ~= nil,
			"scaffolded incubator prompt is not addressable by an exact path"
		)
		-- luau-lsp refuses `player.Team ~= nil` / `== nil` (Team and nil have different
		-- metatables), so the starter tests Team by truthiness.
		assert(
			string.find(server, "Team ~= nil", 1, true) == nil and string.find(server, "Team == nil", 1, true) == nil,
			"scaffolded server compares Team with nil"
		)
		assert(
			string.find(server, "StarterLoop.hatch(", 1, true) ~= nil
				and string.find(server, "StarterLoop.tick(", 1, true) ~= nil
				and string.find(server, "StarterLoop.writeSave(", 1, true) ~= nil,
			"scaffolded server does not run the StarterLoop the smoke drives"
		)
		-- The baseline advanced because of that wrapper and nothing else: the
		-- historical client must still be the one without it.
		assert(
			string.find(original["src/client/CollectProofClient.client.luau"], "CoreUISafeInsets", 1, true) == nil,
			"historical client already had a safe area, so this baseline is stale"
		)
		assert(
			require("../../cli/forge/lib/scaffold").collectRaidFiles == Scaffold.collectRaidFiles,
			"compatibility delegate"
		)
		assert(require("../../cli/forge/lib/planner").renderConfig == Planner.renderConfig, "planner delegate")
	end,
	["planned artifacts are deterministic actual config compiles and dispatches"] = function()
		local generated = assert(Generator.legacy, "collect-raid legacy generation").generate(input)
		local output = files(generated)
		local again = files(assert(Generator.legacy, "collect-raid legacy generation").generate(input))
		for path, content in output do
			assert(again[path] == content, "nondeterministic: " .. path)
			if string.sub(path, -5) == ".luau" then
				assert(type(luau.load(content)) == "function", "generated Luau compiles: " .. path)
			end
		end
		local econ = luau.load(output["src/shared/EconConfig.luau"])()
		local config = luau.load(output["src/shared/Config.luau"], {
			environment = {
				require = function(path)
					if path == "./EconConfig" then
						return econ
					end
					assert(path == "../../../../genres/collect-raid/module/runtime/Loop", "literal native Loop import")
					return Loop
				end,
			},
		})()
		config.profile = { version = 1 }
		config.anticheat = nil
		config.liveops = nil
		config.teams = input.teams
		assert(#Generator.runtime.validateConfig(config) == 0, "actual rendered Loop config validates")
		local now = 0
		local e = Executor.new(
			{ api = 1, order = { "collect-raid" }, configs = { ["collect-raid"] = config } },
			{ Generator.runtime },
			{
				now = function()
					return now
				end,
				roll = function()
					return 0
				end,
				emit = function() end,
			}
		)
		assert(e.join("actual", nil).ok, "actual config joins")
		local source = config.sourceOrder[1]
		assert(e.dispatchClient("actual", "collect-raid:buy-source", { source }).ok, "actual source buys")
		now = config.sources[source].hatchSeconds
		e.advance(now)
		assert(e.dispatchClient("actual", "collect-raid:hatch", { 1 }).ok, "actual source hatches")
		local saved = e.save("actual")
		e.leave("actual")
		assert(e.join("actual", saved).ok, "actual config restores quoted team")
		local catalog = luau.load(output["src/shared/Catalog.luau"])()
		for _, section in { "gamepasses", "products" } do
			for _, entry in catalog[section] do
				assert(entry.grant.kind ~= "random", "paid catalog has no random grants")
				if entry.grant.kind == "kaiju" then
					assert(config.creatures[entry.grant.kaijuId] ~= nil, "fixed paid creature exists")
				end
			end
		end
		local plan = serde.decode("yaml", fs.readFile("genres/collect-raid/econ-template.yml")).plan
		local roster = Planner.buildRoster(input.concept, plan, input.seed)
		assert(
			output["src/shared/Config.luau"] == Planner.renderConfig(roster, Planner.deriveTitle(input.concept), plan),
			"legacy config bytes"
		)
	end,
}
