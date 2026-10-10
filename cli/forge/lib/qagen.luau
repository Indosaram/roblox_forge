--!strict
-- qagen: derives the executable native QA scenario a genre spec implies.
--
-- A spec's `qa.goldenPath` is an ordered action sequence in the *existing*
-- scenario vocabulary (`qascenario.OPERATIONS`, the harness comparators). This
-- module adds identity only: name, genre, pack, kind, contract api, timeout and
-- the declared players. It computes no game rule and invents no expectation, so
-- the derived scenario can never become a second implementation of the
-- behaviour it tests.
--
-- The derived document is validated by `qascenario.validate` before it is ever
-- written or run; `genrespec` reuses the same builder so a spec that cannot
-- produce a valid scenario fails `genreregistry.discover`.
--
-- A pack-local artifact is written as YAML and read back through the same
-- decoder, which coerces a numeric-looking scalar to a number. A spec therefore
-- uses non-numeric player ids and non-numeric string arguments; `genrespec`
-- rejects a string-typed argument that looks numeric rather than letting it
-- reach the domain as a number.

local qascenario = require("./qascenario")

local M = {}

export type Identity = { name: string, genre: string, pack: string }

--- The ordered scenario steps the spec declares, verbatim. An absent or
--- non-list golden path yields no steps, which validation rejects.
function M.steps(spec: any): { any }
	local qa = if type(spec) == "table" then spec.qa else nil
	if type(qa) ~= "table" or type(qa.goldenPath) ~= "table" then
		return {}
	end
	return qa.goldenPath
end

--- The scenario identity a spec's golden path is published under. `name`
--- defaults to `golden-path` so a spec need not repeat it.
function M.name(spec: any): string
	local qa = if type(spec) == "table" then spec.qa else nil
	local name = if type(qa) == "table" then qa.name else nil
	return if type(name) == "string" and #name > 0 then name else "golden-path"
end

--- The golden-path block that applies to a pack running `mode`. A genre whose
--- config selects a mode with its own loop (survival-coop's `crafting`) declares
--- `qa.crafting`; every other mode uses `qa`. The mode block is merged over `qa`,
--- so shared keys (name, players, timeout) are declared once.
function M.block(spec: any, mode: string?): any
	local qa: any = if type(spec) == "table" then spec.qa else nil
	if type(qa) ~= "table" then
		return {}
	end
	local override = if mode ~= nil and type(qa[mode]) == "table" then qa[mode] else nil
	if override == nil then
		return qa
	end
	local merged: any = table.clone(qa)
	for key, value in override do
		merged[key] = value
	end
	return merged
end

--- Builds the native scenario document `spec` implies against `identity`.
function M.derive(spec: any, identity: Identity, mode: string?): any
	local qaTable: any = M.block(spec, mode)
	local document: any = {
		name = M.name(spec),
		genre = identity.genre,
		pack = identity.pack,
		kind = "native",
		contract_api = qascenario.CONTRACT_API,
		timeout_seconds = if type(qaTable.timeout_seconds) == "number"
			then qaTable.timeout_seconds
			else qascenario.HEADLESS_TIMEOUT_SECONDS,
		players = if type(qaTable.players) == "table" then qaTable.players else {},
		steps = if type(qaTable.goldenPath) == "table" then qaTable.goldenPath else {},
	}
	if qaTable.fixtures ~= nil then
		document.fixtures = qaTable.fixtures
	end
	if qaTable.data ~= nil then
		document.data = qaTable.data
	end
	return document
end

--- The pack-local file name of a derived scenario. `:` is not a legal Windows
--- file name character, so the on-disk separator is `.` while the scenario's own
--- `genre`/`name` fields carry the identity.
function M.fileName(genre: string, name: string): string
	return string.format("%s.%s.yml", genre, name)
end

--- The node a derived world path drives: the first node whose control is bound to
--- an action the golden path already exercises *and* whose feedback gives the
--- capture something to show; then the first such node without feedback; then any
--- node with a control. A node that drives an action but shows nothing leaves the
--- capture with no world reaction to record.
function M.worldNode(spec: any): any
	local world = if type(spec) == "table" then spec.world else nil
	if type(world) ~= "table" or type(world.nodes) ~= "table" then
		return nil
	end
	local actions: { [string]: boolean } = {}
	for _, step in M.steps(spec) do
		if type(step) == "table" and type(step.action) == "string" then
			actions[step.action] = true
		end
	end
	local controlActions: { [string]: string } = {}
	for _, row in (if type(spec) == "table" and type(spec.actions) == "table" then spec.actions else {}) do
		if type(row) == "table" and type(row.control) == "table" and type(row.control.id) == "string" then
			controlActions[row.control.id] = tostring(row.action)
		end
	end
	local function shows(node: any): boolean
		return type(node.feedback) == "table" and #node.feedback > 0
	end
	local goldenShows, goldenPlain, fallback = nil, nil, nil
	for _, node in world.nodes do
		if type(node) ~= "table" or type(node.control) ~= "string" then
			continue
		end
		if fallback == nil then
			fallback = node
		end
		local action = controlActions[node.control]
		if action ~= nil and actions[action] then
			if shows(node) and goldenShows == nil then
				goldenShows = node
			elseif not shows(node) and goldenPlain == nil then
				goldenPlain = node
			end
		end
	end
	return goldenShows or goldenPlain or fallback
end

--- The derived world path: the studio scenario that walks the acting player to the
--- spec's node and triggers its ProximityPrompt with real engine input
--- (`walk_to` + `activate_prompt`), then captures the world's reaction. It asserts
--- no rule: it drives the prompt and requires the committed result the server
--- publishes, which is the same `Executor` verdict a HUD press would produce.
--- Returns nil for a genre with no prompt-bearing node, so nothing is published.
function M.deriveWorldPath(spec: any, identity: Identity, mode: string?): any
	local world = if type(spec) == "table" then spec.world else nil
	local node = M.worldNode(spec)
	if type(world) ~= "table" or node == nil then
		return nil
	end
	-- A genre with a declared world override owns its own world builder, so the
	-- shared kit did not place its prompts and cannot promise this path resolves.
	-- Its own scenarios drive its own world instead.
	local overrides = if type(spec) == "table" then spec.overrides else nil
	if type(overrides) == "table" and overrides.world ~= nil then
		return nil
	end
	local qaTable: any = M.block(spec, mode)
	local players: { string } = if type(qaTable.players) == "table" then qaTable.players else {}
	if #players == 0 then
		return nil
	end
	local player = tostring(players[1])
	-- The owned Studio driver runs a multiplayer test, which needs at least two
	-- actors, and every declared player joins so the world has the roster the
	-- scenario assumes. A genre whose spec declares one player gets a peer that
	-- joins and then stands still: the walk and the prompt are the first player's.
	local actors: { string } = {}
	for _, id in players do
		table.insert(actors, tostring(id))
	end
	if #actors < 2 then
		table.insert(actors, player .. "-peer")
	end
	local worldName = if type(world.name) == "string" and #world.name > 0 then world.name else "World"
	local nodePath = string.format("Workspace.%s.Node-%s", worldName, tostring(node.id))
	-- A world that only opens its loop on a clock tick (a boss that spawns on the
	-- schedule, a round that cycles into dressing) declares a prelude in
	-- `qa.worldPath`: an elapsed advance and/or one exact predicate to wait for. It
	-- is the same `advance_elapsed`/`wait_for` vocabulary the golden path uses, and
	-- the derived scenario is validated by `qascenario.validate`, so it cannot name
	-- a step the driver does not implement.
	local worldPathSpec: any = if type(qaTable.worldPath) == "table" then qaTable.worldPath else nil
	local steps: { any } = {
		{ op = "begin_clock" },
	}
	for _, actor in actors do
		table.insert(steps, { op = "join", player = actor })
	end
	if worldPathSpec ~= nil and type(worldPathSpec.advanceSeconds) == "number" then
		table.insert(steps, { op = "advance_elapsed", seconds = worldPathSpec.advanceSeconds })
	end
	if worldPathSpec ~= nil and type(worldPathSpec.waitFor) == "table" then
		local predicate = table.clone(worldPathSpec.waitFor)
		table.insert(steps, {
			op = "wait_for",
			player = player,
			timeout_seconds = if type(worldPathSpec.waitTimeoutSeconds) == "number"
				then worldPathSpec.waitTimeoutSeconds
				else 60,
			predicate = predicate,
		})
	end
	-- Every declared actor needs a device: a capture on a client with no configured
	-- device fails closed, so the layout each client is measured against is explicit.
	for _, actor in actors do
		table.insert(steps, {
			op = "device",
			player = actor,
			surface = "desktop",
			width = 1280,
			height = 720,
			timeout_seconds = 30,
		})
	end
	-- The walk closes to arm's length, not to the step's outer bound: a prompt is only
	-- shown by the engine while the player is genuinely at the node, and a route that
	-- stops eight studs out leaves the prompt unshown (the third-person camera is
	-- further back still). Standing at the node is what "walk to the node" means.
	table.insert(steps, { op = "walk_to", player = player, target = nodePath, withinStuds = 3, timeout_seconds = 120 })
	table.insert(steps, {
		op = "activate_prompt",
		player = player,
		target = nodePath .. "." .. tostring(node.control),
		nodeId = tostring(node.id),
		key = "E",
		timeout_seconds = 60,
		expect = "ok",
	})
	-- The prompt's committed result, read back through the same binding the HUD
	-- uses: the prompt must have driven the action the node is bound to.
	table.insert(steps, { op = "expect_result", player = player, field = "ok", equals = true })
	-- The capture settles first: the action just committed, so the HUD renders the new state a frame
	-- or two later, and the capture's own before/after comparison is strict.
	table.insert(steps, { op = "capture", target = identity.genre .. "-prompt-action", settle = true })
	return {
		name = "world-path",
		genre = identity.genre,
		pack = identity.pack,
		kind = "studio",
		contract_api = qascenario.CONTRACT_API,
		timeout_seconds = 600,
		players = actors,
		steps = steps,
	}
end

return M
