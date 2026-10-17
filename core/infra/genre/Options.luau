--!strict
local Contract = require("../../domain/genre/Contract")
local Executor = require("../../domain/genre/Executor")
local Validation = require("../../domain/genre/Validation")
local Schema = require("../net/Schema")
local ProfileStore = require("../data/ProfileStore")
local Ledger = require("../../domain/command/Ledger")
local Clock = require("./Clock")
export type Control = {
	id: string,
	action: string,
	args: { any },
	label: string,
	kind: "button" | "prompt" | "player-button",
}
export type Services = {
	survivalSpatial: any?,
	survivalDeath: any?,
	survivalSettlement: any?,
	survivalTransfer: any?,
	survivalGathering: any?,
	survivalWildlife: any?,
	survivalExtensions: { Contract.Extension }?,
}
export type Options = {
	clock: Clock.Clock?,
	starterWorld: boolean?,
	-- Server calls bind before installing ingress or launching existing-player joins.
	lifecycle: { bind: (any) -> (), close: () -> Contract.Result }?,
	services: Services?,
	packConfig: Contract.PackConfig,
	contracts: { Contract.RuntimeContract },
	controls: { Control },
	storeName: string,
	hooks: Contract.HookMap?,
	backend: ProfileStore.Backend?,
	durable: Ledger.Policy?,
	-- The pack's serialized genre spec, so a server-side presenter can read the declared
	-- presentation bindings (outfit feedback) without a second copy of them.
	spec: any?,
	-- Seed for the server randomness stream; absent means time-derived (logged at start).
	seed: number?,
}
local M = {}
local EXTENSION_REQUIRED = { "handles", "command" }
local EXTENSION_OPTIONAL = { "snapshot", "recover", "epoch", "observe" }
function M.validateExtensions(list: any): ()
	assert(Validation.dense(list, 64), "services: invalid extension list")
	local seen: { [string]: boolean } = {}
	for _, extension in list do
		assert(type(extension) == "table", "services: invalid extension")
		assert(Validation.id(extension.id) and not seen[extension.id], "services: invalid/duplicate extension id")
		seen[extension.id] = true
		for key, value in extension do
			if key == "id" then
				continue
			end
			assert(
				table.find(EXTENSION_REQUIRED, key) or table.find(EXTENSION_OPTIONAL, key),
				"services: unknown extension field"
			)
			assert(type(value) == "function", "services: invalid extension callback")
		end
		for _, key in EXTENSION_REQUIRED do
			assert(type(extension[key]) == "function", "services: missing extension callback")
		end
	end
end
function M.validateControls(controls: any, contracts: { Contract.RuntimeContract }): ()
	assert(Validation.dense(controls, 1024), "controls: expected dense list")
	local actions: { [string]: Contract.Action } = {}
	for _, descriptor in contracts do
		for _, action in descriptor.actions do
			actions[descriptor.id .. ":" .. action.id] = action
		end
	end
	local seen: { [string]: boolean } = {}
	for _, control in controls do
		assert(type(control) == "table" and Executor.data(control), "control: invalid data")
		for key in control do
			assert(table.find({ "id", "action", "args", "label", "kind" }, key), "control: unknown field")
		end
		assert(
			type(control.id) == "string"
				and #control.id <= 128
				and string.match(control.id, "^[a-z][a-z0-9%-]*:[a-z][a-z0-9%-]*$")
				and not seen[control.id],
			"control: invalid/duplicate namespaced id"
		)
		seen[control.id] = true
		assert(
			type(control.label) == "string" and #control.label > 0 and #control.label <= 128,
			"control: invalid label"
		)
		assert(
			control.kind == "button" or control.kind == "prompt" or control.kind == "player-button",
			"control: invalid kind"
		)
		local action = actions[control.action]
		assert(action and action.origin == "client", "control: undeclared client action")
		assert(
			string.match(control.id, "^([^:]+):") == string.match(control.action, "^([^:]+):"),
			"control: namespace mismatch"
		)
		assert(Validation.dense(control.args, 1024), "control: invalid tuple")
		local offset = if control.kind == "player-button" then 1 else 0
		assert(#control.args + offset == #action.args, "control: invalid arity")
		if offset == 1 then
			assert(action.args[1].kind == "string", "control: roster argument must be a player ID string")
		end
		for index, arg in control.args do
			local valid, reason = Schema.check(Schema.tuple({ action.args[index + offset] }), { arg })
			assert(valid, "control: " .. tostring(reason))
		end
	end
end
function M.validate(options: Options): ()
	assert(type(options) == "table", "options: expected table")
	for key in options do
		assert(
			table.find({
				"packConfig",
				"contracts",
				"controls",
				"storeName",
				"hooks",
				"backend",
				"durable",
				"services",
				"lifecycle",
				"clock",
				"starterWorld",
				"spec",
				"seed",
			}, tostring(key)),
			"options: unknown field"
		)
	end
	assert(
		type(options.storeName) == "string"
			and #options.storeName > 0
			and #options.storeName <= 50
			and string.match(options.storeName, "^[%w_%-]+$"),
		"options: invalid storeName"
	)
	assert(Validation.dense(options.contracts, 64) and #options.contracts > 0, "options: invalid contracts")
	for _, descriptor in options.contracts do
		assert(#Validation.validateRuntime(descriptor) == 0, "options: invalid contract")
	end
	assert(options.hooks == nil or type(options.hooks) == "table", "options: invalid hooks")
	if options.hooks then
		for _, hook in options.hooks do
			assert(type(hook) == "function", "options: invalid hook callback")
		end
	end
	assert(
		options.backend == nil or (type(options.backend) == "table" and type(options.backend.update) == "function"),
		"options: invalid backend"
	)
	assert(
		type(options.packConfig) == "table"
			and type(options.packConfig.configs) == "table"
			and Executor.data(options.packConfig),
		"options: invalid packConfig"
	)
	M.validateControls(options.controls, options.contracts)
	assert(
		options.seed == nil
			or (
				type(options.seed) == "number"
				and options.seed >= 0
				and options.seed <= 9007199254740991
				and options.seed % 1 == 0
			),
		"seed: expected non-negative safe integer"
	)
	assert(options.starterWorld == nil or type(options.starterWorld) == "boolean", "starterWorld: expected boolean")
	if options.clock ~= nil then
		assert(type(options.clock) == "table", "clock: expected table")
		local callbacks = { "now", "begin", "advanceTo", "advanceElapsed" }
		for key in options.clock do
			assert(type(key) == "string" and table.find(callbacks, key), "clock: unknown field")
		end
		for _, key in callbacks do
			assert(type((options.clock :: any)[key]) == "function", "clock: missing callback")
		end
	end
	if options.lifecycle then
		assert(type(options.lifecycle) == "table", "lifecycle: expected table")
		for key in options.lifecycle do
			assert(key == "bind" or key == "close", "lifecycle: unknown field")
		end
		assert(
			type(options.lifecycle.bind) == "function" and type(options.lifecycle.close) == "function",
			"lifecycle: missing callback"
		)
	end
	if options.services then
		local ports: { [string]: any } = options.services :: any
		for name, port in ports do
			if name == "survivalExtensions" then
				M.validateExtensions(port)
				continue
			end
			assert(
				name == "survivalSpatial"
					or name == "survivalDeath"
					or name == "survivalSettlement"
					or name == "survivalTransfer"
					or name == "survivalGathering"
					or name == "survivalWildlife",
				"services: unsupported port"
			)
			assert(type(port) == "table", "services: expected port")
			local required: { string } = if name == "survivalSpatial"
				then { "campfire" }
				elseif name == "survivalDeath" then { "equipment", "position", "reachable" }
				elseif name == "survivalTransfer" then { "handles", "epoch", "command", "recover" }
				elseif name == "survivalGathering" or name == "survivalWildlife" then {
					"handles",
					"command",
					"recover",
					"snapshot",
				}
				else { "handles", "epoch", "command", "snapshot", "link" }
			for _, key in required do
				assert(type(port[key]) == "function", "services: missing callback")
			end
			for key, value in port do
				assert(
					table.find(required, key)
						or (name == "survivalSpatial" and key == "station")
						or (name == "survivalDeath" and key == "worldRevision"),
					"services: unknown field"
				)
				if key ~= "worldRevision" then
					assert(type(value) == "function", "services: invalid callback")
				end
			end
			if name == "survivalDeath" then
				assert(
					type(port.worldRevision) == "string" and #port.worldRevision > 0 and #port.worldRevision <= 128,
					"services: invalid world revision"
				)
			end
		end
	end
	if options.durable ~= nil then
		local policy = options.durable
		assert(type(policy) == "table", "durable: expected policy")
		for key in policy do
			assert(
				table.find(
					{ "actions", "serverActions", "tickAction", "personal", "windowSeconds", "maxOutcomes" },
					tostring(key)
				),
				"durable: unknown field"
			)
		end
		assert(Validation.dense(policy.actions, 1024), "durable: expected actions")
		if policy.personal then
			local personal = policy.personal
			for key in personal do
				assert(key == "namespace" or key == "inventoryPath", "personal: unknown field")
			end
			assert(
				type(personal.namespace) == "string"
					and #personal.namespace > 0
					and #personal.namespace <= 24
					and string.match(personal.namespace, "^[%w_-]+$"),
				"personal: invalid namespace"
			)
			assert(
				Validation.dense(personal.inventoryPath, 12) and #personal.inventoryPath > 0,
				"personal: invalid inventory path"
			)
			for _, key in personal.inventoryPath do
				assert(
					type(key) == "string" and #key > 0 and #key <= 128 and not string.find(key, "%c"),
					"personal: invalid inventory path key"
				)
			end
		end
		assert(
			policy.serverActions == nil or Validation.dense(policy.serverActions, 1024),
			"durable: invalid server actions"
		)
		assert(#policy.actions + #(policy.serverActions or {}) > 0, "durable: expected actions")
		local seen = {}
		if policy.tickAction ~= nil then
			assert(
				type(policy.tickAction) == "string" and table.find(policy.serverActions or {}, policy.tickAction),
				"durable: tickAction must be a server action"
			)
			for _, descriptor in options.contracts do
				for _, action in descriptor.actions do
					if descriptor.id .. ":" .. action.id == policy.tickAction then
						assert(#action.args == 0, "durable: tickAction requires empty tuple")
					end
				end
			end
		end
		local origins: { [string]: { string } } = { client = policy.actions, server = policy.serverActions or {} }
		for origin, ids in origins do
			for _, id in ids do
				assert(type(id) == "string" and not seen[id], "durable: duplicate/invalid action")
				seen[id] = true
				local found = false
				for _, descriptor in options.contracts do
					for _, action in descriptor.actions do
						if descriptor.id .. ":" .. action.id == id and action.origin == origin then
							found = true
						end
					end
				end
				assert(found, "durable: undeclared " .. origin .. " action")
			end
		end
		assert(
			policy.windowSeconds == nil
				or (
					Validation.finite(policy.windowSeconds)
					and policy.windowSeconds >= 1
					and policy.windowSeconds <= 86400
				),
			"durable: invalid TTL"
		)
		assert(
			policy.maxOutcomes == nil
				or (
					Validation.finite(policy.maxOutcomes)
					and policy.maxOutcomes >= 1
					and policy.maxOutcomes <= 4096
					and policy.maxOutcomes % 1 == 0
				),
			"durable: invalid capacity"
		)
	end
end
return M
