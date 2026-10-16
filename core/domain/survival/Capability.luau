--!strict
-- Capability: the survival mode capability contract.
--
-- A survival pack runs in exactly one mode:
--   * `wave`     - the legacy camp-defense loop. Default when the pack config
--                  declares no mode at all, so every existing pack keeps its
--                  exact config/save/action surface.
--   * `crafting` - the gather/craft/build loop. It declares its own action,
--                  save and content versions, and it declares which features
--                  are actually IMPLEMENTED today.
--
-- `features` is an honesty contract, not a wish list. A feature is listed in
-- `implemented` only when a real mechanism backs it; everything else stays in
-- `declared`, and `Capability.assertSupported` refuses any request for a
-- declared-but-unimplemented feature instead of silently succeeding. Later
-- tasks flip entries from declared to implemented as they land the mechanism.

local Validation = require("../genre/Validation")

local M = {}

export type Mode = "wave" | "crafting"
export type Descriptor = {
	mode: Mode,
	actionVersion: number,
	saveVersion: number,
	contentVersion: number?,
	actions: { string },
	features: { declared: { string }, implemented: { string } },
}

local DEFAULT_MODE: Mode = "wave"
M.DEFAULT_MODE = DEFAULT_MODE

--- Every feature the crafting mode will eventually expose. The ordering is
--- the ownership order of the plan's wave 2-3 tasks.
local CRAFTING_FEATURES = {
	"inventory",
	"crafting-jobs",
	"gathering",
	"vitals",
	"placement",
	"tribe",
	"wildlife",
	"transfer",
}
M.CRAFTING_FEATURES = CRAFTING_FEATURES

--- Legacy camp defense. Unchanged from the shipped contract: the same two
--- actions, the same save version 1, no content catalog.
local WAVE: Descriptor = {
	mode = "wave",
	actionVersion = 1,
	saveVersion = 1,
	contentVersion = nil,
	actions = { "buy-defense", "defend-active" },
	features = { declared = {}, implemented = {} },
}

--- Crafting mode. Distinct action/save versions so a crafting save can never
--- be read as a wave save, and vice versa.
--
-- Vitals actions are bound when content.vitals is configured. The complete
-- vitals capability remains missing until death inventory and engine movement
-- integration are proven; action presence alone is not feature completion.
local CRAFTING: Descriptor = {
	mode = "crafting",
	actionVersion = 2,
	-- 3: the crafting slice gained `skills` (craft mastery). v2 saves upgrade
	-- losslessly through CraftingAdapter.upgradeSave.
	saveVersion = 3,
	contentVersion = 1,
	actions = {
		"gather",
		"transfer-deposit",
		"transfer-withdraw",
		"inventory-move",
		"inventory-split",
		"inventory-merge",
		"inventory-reserve",
		"inventory-release",
		"inventory-consume",
		"food",
		"rest",
		"respawn",
		"vitals-damage",
		"rest-stop",
		"server-vitals-tick",
		"death-drop",
		"death-pickup",
		"death-expire",
		"craft-reserve",
		"craft-start",
		"craft-complete",
		"craft-cancel",
		"settlement-invite",
		"settlement-leave",
		"settlement-kick",
		"settlement-transfer-owner",
		"settlement-rejoin",
		"settlement-reserve",
		"settlement-place",
		"settlement-cancel",
		"settlement-demolish",
		"settlement-workshop-reserve",
		"settlement-workshop-start",
		"settlement-workshop-complete",
		"settlement-workshop-cancel",
	},
	features = { declared = CRAFTING_FEATURES, implemented = { "inventory", "crafting-jobs", "gathering" } },
}

local DESCRIPTORS: { [string]: Descriptor } = { wave = WAVE, crafting = CRAFTING }

local function copyList(list: { string }): { string }
	local copy: { string } = {}
	for _, value in list do
		table.insert(copy, value)
	end
	return copy
end

local function copy(descriptor: Descriptor): Descriptor
	return {
		mode = descriptor.mode,
		actionVersion = descriptor.actionVersion,
		saveVersion = descriptor.saveVersion,
		contentVersion = descriptor.contentVersion,
		actions = copyList(descriptor.actions),
		features = {
			declared = copyList(descriptor.features.declared),
			implemented = copyList(descriptor.features.implemented),
		},
	}
end

--- Resolves a config's declared mode. `nil` resolves to the legacy `wave`
--- mode: an existing pack that never heard of this field keeps its behaviour.
function M.modeOf(value: any): (Mode?, string?)
	if value == nil then
		return DEFAULT_MODE, nil
	end
	if value ~= "wave" and value ~= "crafting" then
		return nil, "mode: expected wave|crafting"
	end
	return value :: Mode, nil
end

--- The capability descriptor for a mode, as an isolated copy.
function M.describe(mode: Mode): Descriptor
	local descriptor = DESCRIPTORS[mode]
	assert(descriptor ~= nil, "unknown survival mode: " .. tostring(mode))
	return copy(descriptor)
end

--- True when `feature` is backed by a real mechanism in `mode` today.
function M.isImplemented(mode: Mode, feature: string): boolean
	local descriptor = DESCRIPTORS[mode]
	return descriptor ~= nil and table.find(descriptor.features.implemented, feature) ~= nil
end

--- Returns the features a mode declares but has not implemented yet, sorted.
function M.missingFeatures(mode: Mode): { string }
	local descriptor = DESCRIPTORS[mode]
	if descriptor == nil then
		return {}
	end
	local missing: { string } = {}
	for _, feature in descriptor.features.declared do
		if table.find(descriptor.features.implemented, feature) == nil then
			table.insert(missing, feature)
		end
	end
	table.sort(missing)
	return missing
end

--- Fails closed: an unimplemented feature is an error naming the feature, not
--- a quiet no-op that a caller could mistake for working behaviour.
function M.assertSupported(mode: Mode, feature: string): (boolean, string?)
	local descriptor = DESCRIPTORS[mode]
	if descriptor == nil then
		return false, "unknown survival mode: " .. tostring(mode)
	end
	if table.find(descriptor.features.declared, feature) == nil then
		return false, string.format("%s: feature %q is not declared by this mode", mode, feature)
	end
	if table.find(descriptor.features.implemented, feature) == nil then
		return false, string.format("%s: feature %q is declared but not implemented yet", mode, feature)
	end
	return true, nil
end

--- Validates a capability descriptor shape. Used by the CLI so a future mode
--- cannot ship a malformed or self-contradicting declaration.
function M.validateDescriptor(raw: any): { string }
	local errors: { string } = {}
	if type(raw) ~= "table" then
		return { "capability: expected descriptor" }
	end
	if raw.mode ~= "wave" and raw.mode ~= "crafting" then
		table.insert(errors, "capability.mode: expected wave|crafting")
	end
	for _, field in { "actionVersion", "saveVersion" } do
		local value = raw[field]
		if not Validation.finite(value) or value % 1 ~= 0 or value < 1 or value > 64 then
			table.insert(errors, "capability." .. field .. ": expected integer 1..64")
		end
	end
	if raw.contentVersion ~= nil and raw.contentVersion ~= 1 then
		table.insert(errors, "capability.contentVersion: unsupported version")
	end
	if not Validation.dense(raw.actions, 64) then
		table.insert(errors, "capability.actions: expected dense list")
	end
	local features = raw.features
	if
		type(features) ~= "table"
		or not Validation.dense(features.declared, 64)
		or not Validation.dense(features.implemented, 64)
	then
		table.insert(errors, "capability.features: expected declared/implemented dense lists")
	else
		for _, feature in features.implemented do
			if table.find(features.declared, feature) == nil then
				table.insert(errors, "capability.features: implemented feature is not declared: " .. tostring(feature))
			end
		end
	end
	table.sort(errors)
	return errors
end

return M
