--!strict
-- qascenario: the declarative schema for native QA scenarios executed by
-- `lune run cli/forge qa run`.
--
-- A scenario describes WHAT to drive and WHAT must hold. It never carries
-- game rules: every step maps onto an operation the real Session/Executor
-- already exposes (the same generic ForgeQA surface Studio binds -- dispatch,
-- snapshot, advanceTo, beginClock, advanceElapsed, save, restore), and every
-- assertion is a comparison against a snapshot/result field. There is no place
-- in this schema to express a rule, so a scenario can never become a second
-- implementation of the behaviour it is supposed to test.
--
-- Bounds come from the plan's binding clarifications: a headless scenario is
-- capped at 120s, a first-play/Studio scenario at 20 minutes.

local Validation = require("../../../core/domain/genre/Validation")
local SerializedData = require("../../../core/domain/genre/SerializedData")

local M = {}

M.CONTRACT_API = 1
M.HEADLESS_TIMEOUT_SECONDS = 120
M.FIRST_PLAY_TIMEOUT_SECONDS = 1200

M.KINDS = { "native", "studio" }

--- Operations that drive the run. Each maps 1:1 onto a real Session call or an
--- injected backend fault; none of them computes a game outcome.
M.OPERATIONS = {
	"join",
	"leave",
	"close",
	"dispatch",
	"server_dispatch",
	"command",
	"command_server",
	"recover_transfers",
	"expect_result",
	"advance_to",
	"begin_clock",
	"advance_elapsed",
	"save",
	"restore",
	"reload",
	"commit_barrier",
	"resume_commit",
	"expect_snapshot",
	"expect_members",
	"capture",
	"server_command",
	"walk_to",
	"activate_prompt",
	"bind_result",
	"keyboard",
	"click",
	"touch",
	"equip",
	"wait_for",
	"rejoin",
	"bind_snapshot",
	"device",
	"motion_begin",
	"motion_end",
	"obstacle",
	"parallel_prompt",
	"path_begin",
	"path_end",
}

--- Operations that assert. A scenario with none of them proves nothing and is
--- rejected: a no-op smoke run must never read as coverage.
local ASSERTIONS = { "expect_snapshot", "expect_members", "expect_result" }

--- Operations that need a real rendered client through Studio MCP.
M.STUDIO_ONLY_OPERATIONS = {
	"capture",
	"server_command",
	"walk_to",
	"activate_prompt",
	"bind_result",
	"bind_snapshot",
	"keyboard",
	"click",
	"touch",
	"equip",
	"wait_for",
	"rejoin",
	"device",
	"motion_begin",
	"motion_end",
	"obstacle",
	"parallel_prompt",
	"path_begin",
	"path_end",
}

local COMPARATORS = { "equals", "not_equals", "at_least", "at_most", "is_nil" }

export type Step = {
	op: string,
	player: string?,
	action: string?,
	args: { any }?,
	expect: string?,
	expect_suspended: boolean?,
	genre: string?,
	field: (string | { any })?,
	seconds: number?,
	mode: string?,
	count: number?,
	target: string?,
	members: { string }?,
	[string]: any,
}

export type Scenario = {
	name: string,
	genre: string,
	pack: string,
	kind: string,
	contract_api: number,
	timeout_seconds: number,
	seed: number?,
	players: { string },
	fixtures: { string },
	data: { [string]: any },
	steps: { Step },
}

local function isId(value: any): boolean
	return type(value) == "string" and #value <= 64 and string.match(value, "^[a-z][a-z0-9%-]*$") ~= nil
end

--- Player ids come from YAML, where an unquoted or quoted numeric UserId may
--- decode as a number. Real Roblox ids are numeric, so both forms are accepted
--- and normalized to the string the Session actually keys on.
function M.playerId(value: any): string?
	if type(value) == "number" then
		if value ~= value or value % 1 ~= 0 or value < 0 or value > 2 ^ 53 then
			return nil
		end
		return string.format("%d", value)
	end
	if type(value) ~= "string" or #value == 0 or #value > 64 then
		return nil
	end
	return if string.match(value, "^[%w%-_]+$") ~= nil then value else nil
end

local function isPositiveNumber(value: any): boolean
	return Validation.finite(value) and value > 0
end

local function isNonNegativeNumber(value: any): boolean
	return Validation.finite(value) and value >= 0
end

local function comparatorsOf(step: any): { string }
	local present: { string } = {}
	for _, name in COMPARATORS do
		if step[name] ~= nil then
			table.insert(present, name)
		end
	end
	return present
end

local function validateStep(errors: { string }, index: number, step: any, scenario: any, players: { [string]: boolean })
	local label = string.format("steps[%d]", index)
	if type(step) ~= "table" then
		table.insert(errors, label .. ": expected mapping")
		return
	end
	local op = step.op
	if type(op) ~= "string" or table.find(M.OPERATIONS, op) == nil then
		table.insert(errors, string.format("%s.op: unknown operation %s", label, tostring(op)))
		return
	end
	if scenario.kind == "native" and table.find(M.STUDIO_ONLY_OPERATIONS, op) ~= nil then
		table.insert(errors, string.format("%s.op: '%s' needs a rendered client and cannot run headless", label, op))
	end
	local needsPlayer = table.find({
		"join",
		"leave",
		"close",
		"dispatch",
		"server_dispatch",
		"command",
		"command_server",
		"server_command",
		"walk_to",
		"activate_prompt",
		"bind_result",
		"keyboard",
		"click",
		"touch",
		"equip",
		"wait_for",
		"rejoin",
		"bind_snapshot",
		"device",
		"motion_begin",
		"motion_end",
		"obstacle",
		"path_begin",
		"path_end",
		"recover_transfers",
		"expect_result",
		"save",
		"restore",
		"expect_snapshot",
	}, op) ~= nil
	if needsPlayer then
		local id = M.playerId(step.player)
		if id == nil then
			table.insert(errors, label .. ".player: expected a declared player id")
		elseif not players[id] then
			table.insert(errors, label .. ".player: undeclared player " .. id)
		end
	elseif step.player ~= nil then
		table.insert(errors, string.format("%s.player: not valid for '%s'", label, op))
	end
	if
		(op == "server_dispatch" or op == "command_server" or op == "recover_transfers")
		and scenario.kind ~= "native"
	then
		table.insert(errors, label .. ".op: " .. op .. " is native-only")
	end
	if
		op == "dispatch"
		or op == "command"
		or op == "server_dispatch"
		or op == "command_server"
		or op == "server_command"
	then
		local action = step.action
		if type(action) ~= "string" or string.match(action, "^[a-z][a-z0-9%-]*:[a-z][a-z0-9%-]*$") == nil then
			table.insert(errors, label .. ".action: expected '<genre>:<action>'")
		elseif string.match(action, "^([^:]+):") ~= scenario.genre then
			table.insert(errors, label .. ".action: action is outside the scenario genre")
		end
		if step.args ~= nil and (not Validation.dense(step.args, 16) or not SerializedData.data(step.args)) then
			table.insert(errors, label .. ".args: expected a dense tuple")
		end
		if step.expect ~= nil and step.expect ~= "ok" and step.expect ~= "refused" then
			table.insert(errors, label .. ".expect: expected ok|refused")
		end
		if op == "command" or op == "command_server" then
			if type(step.requestId) ~= "string" or #step.requestId == 0 or #step.requestId > 128 then
				table.insert(errors, label .. ".requestId: expected bounded request id")
			end
			if
				step.sessionEpoch ~= "current"
				and (not isNonNegativeNumber(step.sessionEpoch) or step.sessionEpoch % 1 ~= 0)
			then
				table.insert(errors, label .. ".sessionEpoch: expected epoch integer")
			end
			if step.times ~= nil and (not isPositiveNumber(step.times) or step.times % 1 ~= 0 or step.times > 100) then
				table.insert(errors, label .. ".times: expected integer 1..100")
			end
		end
	elseif step.action ~= nil then
		table.insert(errors, string.format("%s.action: not valid for '%s'", label, op))
	end
	if op == "server_command" then
		if
			type(step.requestId) ~= "string"
			or #step.requestId == 0
			or #step.requestId > 128
			or string.find(step.requestId, "%c")
		then
			table.insert(errors, label .. ".requestId: expected bounded request id without controls")
		end
		for key in step do
			if not table.find({ "op", "player", "requestId", "action", "args", "expect" }, key) then
				table.insert(errors, label .. ": invalid server_command field " .. tostring(key))
			end
		end
	end
	if op == "walk_to" or op == "activate_prompt" then
		local function isWorkspacePath(value: any): boolean
			return type(value) == "string"
				and #value <= 256
				-- A node prompt is named after the namespaced control it drives
				-- (`grow-harvest:seed-shop`), so an instance-name segment may carry a colon.
				and string.match(value, "^Workspace%.[%w_%.%-:]+$") ~= nil
		end
		-- A walk may name one target or several: the driver walks to the nearest of
		-- them, which is how a capture stays deterministic in a world whose spawn is
		-- not fixed (a two-team pack spawns the actor in either base). A prompt is a
		-- specific instance, so `activate_prompt` keeps its single target.
		local multipleTargets = op == "walk_to" and step.targets ~= nil
		if multipleTargets then
			if type(step.targets) ~= "table" or #step.targets == 0 or #step.targets > 8 then
				table.insert(errors, label .. ".targets: expected a non-empty list of at most 8 Workspace paths")
			else
				for slot, candidate in step.targets do
					if not isWorkspacePath(candidate) then
						table.insert(
							errors,
							string.format("%s.targets[%d]: expected bounded Workspace instance path", label, slot)
						)
					end
				end
			end
		elseif not isWorkspacePath(step.target) then
			table.insert(errors, label .. ".target: expected bounded Workspace instance path")
		end
		if not isPositiveNumber(step.timeout_seconds) or step.timeout_seconds > scenario.timeout_seconds then
			table.insert(errors, label .. ".timeout_seconds: expected bounded positive timeout")
		end
		if op == "walk_to" and (not isPositiveNumber(step.withinStuds) or step.withinStuds > 8) then
			table.insert(errors, label .. ".withinStuds: expected positive reach up to 8")
		end
		if
			op == "walk_to"
			and step.verticalToleranceStuds ~= nil
			and (not isPositiveNumber(step.verticalToleranceStuds) or step.verticalToleranceStuds > 8)
		then
			table.insert(errors, label .. ".verticalToleranceStuds: expected positive vertical reach up to 8")
		end
		if op == "activate_prompt" and (step.key ~= "E" or not isId(step.nodeId)) then
			table.insert(errors, label .. ": activate_prompt requires key E and nodeId")
		end
	end
	if op == "activate_prompt" then
		for key in step do
			if
				not table.find(
					{ "op", "player", "target", "nodeId", "key", "timeout_seconds", "expect", "reason" },
					key
				)
			then
				table.insert(errors, label .. ": unknown activate_prompt field " .. tostring(key))
			end
		end
		if step.expect ~= nil and step.expect ~= "ok" and step.expect ~= "refused" then
			table.insert(errors, label .. ".expect: expected ok|refused")
		end
		if step.expect == "refused" then
			if type(step.reason) ~= "string" or not string.match(step.reason, "^[A-Z][A-Z_]+$") then
				table.insert(errors, label .. ".reason: refused prompt requires exact result reason")
			end
		elseif step.reason ~= nil then
			table.insert(errors, label .. ".reason: only valid for refused prompt")
		end
	end
	-- These operations require matching maintained driver capabilities. Schema
	-- acceptance alone never substitutes for actual subscribed input/telemetry.
	if op == "parallel_prompt" or op == "path_begin" or op == "path_end" then
		local allowed = if op == "parallel_prompt"
			then {
				"op",
				"label",
				"timeout_seconds",
				"nodeId",
				"target",
				"key",
				"players",
				"expect",
				"conservation",
				"refusalReasons",
			}
			elseif op == "path_begin" then { "op", "player", "label", "target" }
			else { "op", "player", "label", "target", "timeout_seconds", "outcome" }
		for key in step do
			if not table.find(allowed, key) then
				table.insert(errors, label .. ": unknown " .. op .. " field " .. tostring(key))
			end
		end
		if
			not isId(step.label)
			or type(step.target) ~= "string"
			or not string.match(step.target, "^Workspace%.[%w_%.%-:]+$")
		then
			table.insert(errors, label .. ": label and physical Workspace target required")
		end
		if
			op ~= "path_begin"
			and (not isPositiveNumber(step.timeout_seconds) or step.timeout_seconds > scenario.timeout_seconds)
		then
			table.insert(errors, label .. ".timeout_seconds: bounded positive timeout required")
		end
		if op == "path_end" and step.outcome ~= "recovered" and step.outcome ~= "refused" then
			table.insert(errors, label .. ".outcome: expected recovered|refused after consumed path failure")
		end
		if op == "parallel_prompt" then
			if step.key ~= "E" or not isId(step.nodeId) then
				table.insert(errors, label .. ": parallel prompt requires E and nodeId")
			end
			local seen = {}
			if not Validation.dense(step.players, 2) or #step.players ~= 2 then
				table.insert(errors, label .. ".players: exactly two distinct declared actors required")
			else
				for _, actor in step.players do
					local id = M.playerId(actor)
					if not id or not players[id] or seen[id] then
						table.insert(errors, label .. ".players: undeclared or duplicate actor")
					else
						seen[id] = true
					end
				end
			end
			if type(step.expect) ~= "table" or step.expect.ok ~= 1 or step.expect.refused ~= 1 then
				table.insert(errors, label .. ".expect: exactly one success and one refusal required")
			end
			for key in if type(step.expect) == "table" then step.expect else {} do
				if key ~= "ok" and key ~= "refused" then
					table.insert(errors, label .. ".expect: unknown field")
				end
			end
			local conservation = step.conservation
			if
				type(conservation) ~= "table"
				or not isId(conservation.catalogId)
				or not isPositiveNumber(conservation.quantityGain)
				or conservation.quantityGain % 1 ~= 0
			then
				table.insert(errors, label .. ".conservation: catalogId and positive integer quantityGain required")
			end
			for key in if type(conservation) == "table" then conservation else {} do
				if key ~= "catalogId" and key ~= "quantityGain" then
					table.insert(errors, label .. ".conservation: unknown field")
				end
			end
			if not Validation.dense(step.refusalReasons, 8) or #step.refusalReasons == 0 then
				table.insert(errors, label .. ".refusalReasons: nonempty exact reasons required")
			else
				for _, reason in step.refusalReasons do
					if type(reason) ~= "string" or not string.match(reason, "^[A-Z][A-Z_]+$") then
						table.insert(errors, label .. ".refusalReasons: invalid reason")
					end
				end
			end
		end
	end
	if
		(op == "bind_result" or op == "bind_snapshot")
		and (
			not isId(step.label)
			or not (
				(type(step.field) == "string" and #step.field > 0 and #step.field <= 128)
				or (op == "bind_snapshot" and Validation.dense(step.field, 32) and #step.field > 0)
			)
		)
	then
		table.insert(errors, label .. ": bind_result requires label and bounded result field")
	end
	if op == "bind_snapshot" and step.select ~= nil then
		local function validCondition(entry: any): boolean
			if type(entry) ~= "table" or type(entry.field) ~= "string" then
				return false
			end
			-- `empty` survives the Luau round trip, where an authored empty array would
			-- collapse into an empty table.
			return entry.equals ~= nil or entry.empty == true
		end
		local valid = false
		if type(step.select) == "table" then
			if validCondition(step.select) then
				valid = true
			elseif #step.select > 0 then
				valid = true
				for _, entry in step.select do
					if not validCondition(entry) then
						valid = false
						break
					end
				end
			end
		end
		if not valid then
			table.insert(
				errors,
				label
					.. ": select requires field and equals (one condition or a non-empty list); exactly one matching key must exist"
			)
		end
	end
	if op == "device" then
		if
			not (
				(step.surface == "desktop" and step.width == 1280 and step.height == 720)
				or (step.surface == "mobile" and step.width == 390 and step.height == 844)
			)
		then
			table.insert(errors, label .. ": expected desktop 1280x720 or mobile 390x844")
		end
	end
	if op == "motion_begin" or op == "motion_end" or op == "obstacle" then
		if type(step.target) ~= "string" or not string.match(step.target, "^Workspace%.[%w_%.%-:]+$") then
			table.insert(errors, label .. ": physical Workspace target required")
		end
	end
	if op == "capture" and step.angles ~= nil and step.angles ~= 3 then
		table.insert(errors, label .. ": angles must be 3")
	end
	-- `settle` waits, bounded, for the owned UI to stop changing before the screenshot. The capture's
	-- own before/after comparison stays strict, so a HUD still moving is reported rather than
	-- captured mid-change.
	if op == "capture" and step.settle ~= nil and type(step.settle) ~= "boolean" then
		table.insert(errors, label .. ".settle: expected boolean")
	end
	-- `layers` renders only the owned UI or only the 3D world; the driver hides the other layer around
	-- the screenshot and restores it. Absent means everything.
	if op == "capture" and step.layers ~= nil and not table.find({ "all", "world", "ui" }, step.layers) then
		table.insert(errors, label .. ".layers: expected all|world|ui")
	end
	if table.find({ "keyboard", "click", "touch", "equip", "wait_for", "rejoin", "device" }, op) then
		if not isPositiveNumber(step.timeout_seconds) or step.timeout_seconds > scenario.timeout_seconds then
			table.insert(errors, label .. ".timeout_seconds: expected bounded positive timeout")
		end
		if op == "keyboard" and (type(step.key) ~= "string" or not string.match(step.key, "^[%w]+$")) then
			table.insert(errors, label .. ".key: expected KeyCode name")
		end
		if
			(op == "click" or op == "touch" or op == "equip")
			and type(step.target) ~= "string"
			and type(step.target) ~= "table"
		then
			table.insert(errors, label .. ".target: expected instance path segments")
		end
		if op == "touch" then
			for key in step do
				if
					not table.find({
						"op",
						"player",
						"target",
						"timeout_seconds",
						"untilState",
						"resultAction",
						"expect",
						"nodeId",
					}, key)
				then
					table.insert(errors, label .. ": unknown touch field " .. tostring(key))
				end
			end
			if step.expect ~= nil and step.expect ~= "ok" and step.expect ~= "refused" then
				table.insert(errors, label .. ".expect: expected ok|refused")
			end
			if step.nodeId ~= nil and (not isId(step.nodeId) or step.resultAction ~= nil) then
				table.insert(errors, label .. ": gather touch requires nodeId and no HUD resultAction")
			end
		end
		if op == "wait_for" or step.untilState ~= nil then
			local predicate = if op == "wait_for" then step.predicate else step.untilState
			if type(predicate) ~= "table" then
				table.insert(errors, label .. ": exact predicate required")
			elseif not table.find({ "property", "attribute", "snapshot" }, predicate.source) then
				table.insert(errors, label .. ": predicate source must be property|attribute|snapshot")
			else
				if #comparatorsOf(predicate) ~= 1 then
					table.insert(errors, label .. ": predicate needs exactly one comparator")
				end
				if predicate.source == "snapshot" then
					if type(predicate.field) ~= "string" and type(predicate.field) ~= "table" then
						table.insert(errors, label .. ": snapshot field required")
					end
				elseif type(predicate.target) ~= "string" or type(predicate.field) ~= "string" then
					table.insert(errors, label .. ": instance predicate requires target and field")
				end
			end
		end
		if
			step.resultAction ~= nil
			and (
				type(step.resultAction) ~= "string" or not string.match(step.resultAction, "^survival%-coop:[a-z%-]+$")
			)
		then
			table.insert(errors, label .. ": invalid HUD result action")
		end
	end
	if op == "recover_transfers" then
		if not Validation.finite(step.maximum) or step.maximum % 1 ~= 0 or step.maximum < 1 or step.maximum > 64 then
			table.insert(errors, label .. ".maximum: expected integer 1..64")
		end
	elseif step.maximum ~= nil then
		table.insert(errors, label .. ".maximum: only valid for recover_transfers")
	end
	if op == "advance_to" or op == "advance_elapsed" then
		local value = step.seconds
		local valid = if op == "advance_elapsed" then isNonNegativeNumber(value) else isPositiveNumber(value)
		if not valid then
			table.insert(errors, label .. ".seconds: expected a finite non-negative number")
		end
	elseif step.seconds ~= nil then
		table.insert(errors, string.format("%s.seconds: not valid for '%s'", label, op))
	end
	if op == "commit_barrier" then
		if step.key ~= nil and (type(step.key) ~= "string" or #step.key == 0 or #step.key > 50) then
			table.insert(errors, label .. ".key: invalid backend key")
		end
		if step.skip ~= nil and (not isNonNegativeNumber(step.skip) or step.skip % 1 ~= 0 or step.skip > 16) then
			table.insert(errors, label .. ".skip: invalid commit skip")
		end
		if step.mode ~= "fail" and step.mode ~= "suspend" then
			table.insert(errors, label .. ".mode: expected fail|suspend")
		end
		if step.count ~= nil and (not Validation.finite(step.count) or step.count % 1 ~= 0 or step.count < 1) then
			table.insert(errors, label .. ".count: expected a positive integer")
		end
	elseif step.mode ~= nil or step.count ~= nil then
		table.insert(errors, string.format("%s: mode/count are only valid for commit_barrier", label))
	end
	if
		step.expect_suspended ~= nil
		and op ~= "save"
		and op ~= "close"
		and op ~= "command"
		and op ~= "command_server"
	then
		table.insert(errors, label .. ".expect_suspended: only valid for save|close")
	end
	if op == "expect_snapshot" or op == "expect_result" then
		if step.scope ~= nil and (op ~= "expect_snapshot" or step.scope ~= "session") then
			table.insert(errors, label .. ".scope: expected session snapshot scope")
		end
		if op == "expect_snapshot" and step.scope ~= "session" and not isId(step.genre) then
			table.insert(errors, label .. ".genre: expected a genre id")
		end
		if
			not (type(step.field) == "string" and #step.field > 0 and #step.field <= 128)
			and not (scenario.kind == "studio" and Validation.dense(step.field, 32) and #step.field > 0)
		then
			table.insert(errors, label .. ".field: expected a snapshot field path")
		end
		local present = comparatorsOf(step)
		if #present ~= 1 then
			table.insert(errors, string.format("%s: expected exactly one of %s", label, table.concat(COMPARATORS, "|")))
		elseif (present[1] == "at_least" or present[1] == "at_most") and not Validation.finite(step[present[1]]) then
			table.insert(errors, string.format("%s.%s: expected a finite number", label, present[1]))
		end
	end
	if op == "expect_members" and not Validation.dense(step.members, 64) and next(step.members or {}) ~= nil then
		table.insert(errors, label .. ".members: expected a dense list of player ids")
	end
	if op == "capture" then
		if type(step.target) ~= "string" or #step.target == 0 then
			table.insert(errors, label .. ".target: expected a capture target")
		end
	end
	if op == "restore" and step.from == nil then
		table.insert(errors, label .. ".from: expected the label of a prior save step")
	end
	if op == "save" and step.label ~= nil and not isId(step.label) then
		table.insert(errors, label .. ".label: invalid id")
	end
end

--- Returns every violation in a decoded scenario document, sorted. An empty
--- list means the scenario is well formed; it does not mean it passes.
function M.validate(raw: any): { string }
	if type(raw) ~= "table" then
		return { "scenario: expected mapping" }
	end
	local errors: { string } = {}
	local allowed = {
		"name",
		"genre",
		"pack",
		"kind",
		"contract_api",
		"timeout_seconds",
		"seed",
		"players",
		"fixtures",
		"data",
		"steps",
	}
	for key in raw do
		if type(key) ~= "string" or table.find(allowed, key) == nil then
			table.insert(errors, "scenario: unknown field " .. tostring(key))
		end
	end
	if raw.contract_api ~= M.CONTRACT_API then
		table.insert(errors, "contract_api: unsupported scenario contract " .. tostring(raw.contract_api))
	end
	if not isId(raw.name) then
		table.insert(errors, "name: invalid scenario id")
	end
	if not isId(raw.genre) then
		table.insert(errors, "genre: invalid genre id")
	end
	if not isId(raw.pack) then
		table.insert(errors, "pack: invalid pack slug")
	end
	if type(raw.kind) ~= "string" or table.find(M.KINDS, raw.kind) == nil then
		table.insert(errors, "kind: expected " .. table.concat(M.KINDS, "|"))
	end
	if raw.seed ~= nil then
		if raw.kind ~= "native" then
			table.insert(errors, "seed: only a native scenario may seed the roll stream")
		elseif type(raw.seed) ~= "number" or raw.seed % 1 ~= 0 or raw.seed < 0 or raw.seed > 9007199254740991 then
			table.insert(errors, "seed: expected a non-negative safe integer")
		end
	end
	local cap = if raw.kind == "studio" then M.FIRST_PLAY_TIMEOUT_SECONDS else M.HEADLESS_TIMEOUT_SECONDS
	if not isPositiveNumber(raw.timeout_seconds) or raw.timeout_seconds > cap then
		table.insert(errors, string.format("timeout_seconds: expected a positive number up to %d", cap))
	end
	local players: { [string]: boolean } = {}
	if not Validation.dense(raw.players, 8) or #(raw.players or {}) == 0 then
		table.insert(errors, "players: expected a nonempty dense list")
	else
		for index, id in raw.players do
			local normalized = M.playerId(id)
			if normalized == nil then
				table.insert(errors, string.format("players[%d]: invalid player id", index))
			elseif players[normalized] then
				table.insert(errors, string.format("players[%d]: duplicate player %s", index, normalized))
			else
				players[normalized] = true
			end
		end
	end
	if raw.fixtures ~= nil and not Validation.dense(raw.fixtures, 64) then
		table.insert(errors, "fixtures: expected a dense list of task-owned fixture paths")
	else
		for index, path in raw.fixtures or {} do
			if type(path) ~= "string" or #path == 0 or string.find(path, "..", 1, true) ~= nil then
				table.insert(errors, string.format("fixtures[%d]: unsafe fixture path", index))
			end
		end
	end
	if raw.data ~= nil and type(raw.data) ~= "table" then
		table.insert(errors, "data: expected a mapping")
	end
	if type(raw.data) == "table" and raw.data.settlement ~= nil then
		local fixture = raw.data.settlement
		if raw.kind ~= "native" or type(fixture) ~= "table" then
			table.insert(errors, "data.settlement: native fixture required")
		else
			for key in fixture do
				if not table.find({ "key", "tribeId", "owner", "slots", "items", "positions", "radiusStuds" }, key) then
					table.insert(errors, "data.settlement: unknown field")
				end
			end
			if not isId(fixture.key) or not isId(fixture.tribeId) or not players[fixture.owner] then
				table.insert(errors, "data.settlement: invalid identity")
			end
			if
				not Validation.finite(fixture.slots)
				or fixture.slots % 1 ~= 0
				or fixture.slots < 1
				or fixture.slots > 20
			then
				table.insert(errors, "data.settlement: invalid slots")
			end
			if not Validation.dense(fixture.items, 20) or not SerializedData.data(fixture.items) then
				table.insert(errors, "data.settlement: invalid initial items")
			end
			if not Validation.finite(fixture.radiusStuds) or fixture.radiusStuds <= 0 or fixture.radiusStuds > 512 then
				table.insert(errors, "data.settlement: invalid radius")
			end
			if type(fixture.positions) ~= "table" then
				table.insert(errors, "data.settlement: positions required")
			else
				for actor, position in fixture.positions do
					if not players[actor] or type(position) ~= "table" then
						table.insert(errors, "data.settlement: invalid actor position")
					else
						for key in position do
							if not table.find({ "x", "y", "z" }, key) then
								table.insert(errors, "data.settlement: unknown coordinate")
							end
						end
						for _, axis in { "x", "y", "z" } do
							if not Validation.finite(position[axis]) or math.abs(position[axis]) > 1000000 then
								table.insert(errors, "data.settlement: invalid coordinate")
							end
						end
					end
				end
			end
		end
	end
	if type(raw.data) == "table" and raw.data.survivalSpatial ~= nil then
		local spatial = raw.data.survivalSpatial
		if raw.kind ~= "native" or type(spatial) ~= "table" then
			table.insert(errors, "data.survivalSpatial: expected native coordinate fixture")
		else
			for key in spatial do
				if not table.find({ "radiusStuds", "players", "campfires", "stations" }, key) then
					table.insert(errors, "data.survivalSpatial: unknown field")
				end
			end
			if not Validation.finite(spatial.radiusStuds) or spatial.radiusStuds <= 0 or spatial.radiusStuds > 512 then
				table.insert(errors, "data.survivalSpatial.radiusStuds: expected finite 0..512")
			end
			for _, field in { "players", "campfires", "stations" } do
				local positions = spatial[field]
				if field == "stations" and positions == nil then
					continue
				end
				if type(positions) ~= "table" then
					table.insert(errors, "data.survivalSpatial." .. field .. ": expected positions")
				else
					local count = 0
					for id, position in positions do
						count += 1
						local normalized = if field == "players" then M.playerId(id) else id
						if
							type(normalized) ~= "string"
							or #normalized == 0
							or #normalized > 64
							or (field == "players" and not players[normalized])
						then
							table.insert(errors, "data.survivalSpatial: invalid identity")
						end
						if type(position) ~= "table" then
							table.insert(errors, "data.survivalSpatial: expected coordinate")
						else
							for key in position do
								if
									not table.find({ "x", "y", "z" }, key)
									and not (field == "stations" and key == "kind")
								then
									table.insert(errors, "data.survivalSpatial: unknown coordinate")
								end
							end
							if
								field == "stations"
								and (
									type(position.kind) ~= "string"
									or #position.kind == 0
									or #position.kind > 64
									or string.find(position.kind, "%c")
								)
							then
								table.insert(errors, "data.survivalSpatial: invalid station kind")
							end
							for _, axis in { "x", "y", "z" } do
								if not Validation.finite(position[axis]) or math.abs(position[axis]) > 1000000 then
									table.insert(errors, "data.survivalSpatial: invalid bounded coordinate")
								end
							end
						end
					end
					if count == 0 or count > 64 then
						table.insert(errors, "data.survivalSpatial: expected 1..64 positions")
					end
				end
			end
		end
	end
	if not Validation.dense(raw.steps, 512) or #(raw.steps or {}) == 0 then
		table.insert(errors, "steps: expected a nonempty dense list")
	else
		local asserted = false
		for index, step in raw.steps do
			validateStep(errors, index, step, raw, players)
			if type(step) == "table" and table.find(ASSERTIONS, step.op) ~= nil then
				asserted = true
			end
		end
		if not asserted then
			table.insert(
				errors,
				"steps: a scenario must assert at least once (" .. table.concat(ASSERTIONS, "|") .. ")"
			)
		end
		if raw.kind == "studio" then
			local bindings: { [string]: boolean } = {}
			local paths = {}
			local promptGroups: { [string]: boolean } = {}
			for index, step in raw.steps do
				if type(step) ~= "table" then
					continue
				end
				if step.op == "parallel_prompt" and isId(step.label) then
					if promptGroups[step.label] then
						table.insert(errors, "duplicate prompt group " .. step.label)
					end
					promptGroups[step.label] = true
				end
				if step.op == "path_begin" and isId(step.label) then
					if paths[step.label] then
						table.insert(errors, "duplicate path subscription " .. step.label)
					end
					paths[step.label] = { player = step.player, target = step.target, closed = false }
				elseif step.op == "path_end" and isId(step.label) then
					local opened = paths[step.label]
					if not opened or opened.closed or opened.player ~= step.player or opened.target ~= step.target then
						table.insert(errors, "path_end requires matching open subscription " .. step.label)
					else
						opened.closed = true
					end
				end
				for _, tuple in
					{
						step.args or {},
						if type(step.field) == "table" then step.field else {},
						if type(step.target) == "table" then step.target else {},
						if type(step.predicate) == "table" and type(step.predicate.field) == "table"
							then step.predicate.field
							else {},
					}
				do
					if type(tuple) ~= "table" then
						continue
					end
					for _, value in tuple do
						if type(value) == "table" and value.ref ~= nil then
							local count = 0
							for _ in value do
								count += 1
							end
							if
								(count ~= 1 and not (count == 2 and type(value.prefix) == "string"))
								or not isId(value.ref)
								or not bindings[value.ref]
							then
								table.insert(
									errors,
									string.format("steps[%d]: invalid or forward binding reference", index)
								)
							end
						elseif tuple == step.field and type(value) ~= "string" then
							table.insert(
								errors,
								string.format("steps[%d]: field segment must be string or reference", index)
							)
						end
					end
				end
				for _, predicate in { step.predicate or {}, step.untilState or {} } do
					for _, comparator in COMPARATORS do
						local value = predicate[comparator]
						if type(value) == "table" and (not isId(value.ref) or not bindings[value.ref]) then
							table.insert(errors, string.format("steps[%d]: invalid predicate binding", index))
						end
					end
				end
				for _, value in step.args or {} do
					if type(value) == "table" and value.player ~= nil and not players[value.player] then
						table.insert(errors, string.format("steps[%d]: unknown actor reference", index))
					end
				end
				if (step.op == "bind_result" or step.op == "bind_snapshot") and isId(step.label) then
					if bindings[step.label] then
						table.insert(errors, "duplicate binding " .. step.label)
					end
					bindings[step.label] = true
				end
			end
			for label, opened in paths do
				if not opened.closed then
					table.insert(errors, "unclosed path subscription " .. label)
				end
			end
			local captured = false
			for _, step in raw.steps do
				if type(step) == "table" and step.op == "capture" then
					captured = true
				end
			end
			if not captured then
				table.insert(errors, "steps: a studio scenario must capture the rendered client at least once")
			end
		end
	end
	table.sort(errors)
	return errors
end

--- The on-disk location of a scenario. Native scenarios live beside the genre's
--- existing qa-scenarios so one directory remains the scenario source of truth.
function M.path(genreRoot: string, genre: string, name: string): string
	return string.format("%s/%s/qa-scenarios/%s.yml", genreRoot, genre, name)
end

return M
