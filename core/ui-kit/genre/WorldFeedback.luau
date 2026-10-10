--!strict
-- WorldFeedback: the world's visible reaction to the actions the spec binds.
--
-- The spec already declares which node carries which control (`world.nodes[].
-- control`); this module declares what each node *shows* when the domain state
-- behind it changes. It is presentation only: every value it reads is a
-- snapshot field the adapter already publishes, and every cue it plays is a cue
-- the spec already declares. It computes no outcome, so `Executor` stays the
-- only validator.
--
-- Two layers, one authority:
--
--   * The pure layer (`bindings`, `state`, `deltas`, `violations`) turns a spec
--     and two snapshots into the visual state of each node and the floating-text
--     lines between them. It names no Roblox global, so `forge sweep` and the
--     specs measure exactly the numbers the runtime applies.
--   * `start` applies that state to the world the place already carries: a crop
--     that grows through its stages, a health bar billboard over an enemy that
--     empties and reports a defeat, a queue pad that lights, an outfit worn on
--     the local character, a floating-text popup, and the bound audio cue.
--
-- The node instances are addressed by the `ForgeNodeId` attribute `WorldKit`
-- already stamps on every node part, so a baked world and a runtime-built world
-- are the same world to this module.

local M = {}

--- The closed feedback vocabulary. Each kind reads one snapshot field and maps it
--- to one visual channel:
---   growth  - a plot's crop: empty, growing, or ready
---   health  - an enemy's remaining health: a billboard bar, and a defeat at zero
---   lamp    - a pad that lights while a field holds its `active` value
---   outfit  - an outfit id worn on the character while the field holds it
---   counter - a number that only speaks through its floating-text delta
M.KINDS = { "growth", "health", "lamp", "outfit", "counter" }

local KIND_SET: { [string]: boolean } = {}
for _, kind in M.KINDS do
	KIND_SET[kind] = true
end

--- Reads a dotted snapshot path (`plots.1`, `activeBosses.slime`, `equipped`).
function M.value(snapshot: any, path: any): any
	if type(path) ~= "string" then
		return nil
	end
	local current = snapshot
	for segment in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return nil
		end
		local index = tonumber(segment)
		current = if index ~= nil then current[index] else current[segment]
	end
	return current
end

--- Every feedback binding the spec declares, in node order, flattened to one row
--- per binding with the node it belongs to.
function M.bindings(world: any): { any }
	local out: { any } = {}
	local nodes = if type(world) == "table" and type(world.nodes) == "table" then world.nodes else {}
	for _, node in nodes do
		if type(node) ~= "table" or type(node.feedback) ~= "table" then
			continue
		end
		for _, entry in node.feedback do
			if type(entry) == "table" then
				table.insert(out, {
					nodeId = tostring(node.id),
					nodeKind = node.kind,
					control = node.control,
					kind = entry.kind,
					field = entry.field,
					entity = entry.entity,
					stages = entry.stages,
					active = entry.active,
					max = entry.max,
					label = entry.label,
					labelKey = entry.labelKey,
					cue = entry.cue,
				})
			end
		end
	end
	return out
end

--- True when any value of a table field equals `target` (an `equipped` map).
local function holds(table_: any, target: any): boolean
	if type(table_) ~= "table" then
		return false
	end
	for _, value in table_ do
		if value == target then
			return true
		end
	end
	return false
end

--- The pure visual state one binding implies for a snapshot. Returns a table
--- whose fields the runtime reads directly, so the gate and the renderer can
--- never disagree about what a node shows.
function M.state(binding: any, snapshot: any): any
	local value = M.value(snapshot, binding.field)
	if binding.kind == "growth" then
		local cropId = if type(value) == "table" then value.cropId else nil
		local ready = type(value) == "table" and value.ready == true
		local stage = if cropId == nil then 0 elseif ready then 2 else 1
		return { stage = stage, cropId = cropId, ready = ready }
	elseif binding.kind == "health" then
		local number = tonumber(value) or 0
		local maximum = if type(binding.max) == "number" and binding.max > 0 then binding.max else 1
		return {
			value = number,
			max = maximum,
			fraction = math.clamp(number / maximum, 0, 1),
			defeated = number <= 0,
		}
	elseif binding.kind == "lamp" then
		return { active = value ~= nil and value == binding.active }
	elseif binding.kind == "outfit" then
		return { worn = holds(value, binding.entity) }
	end
	return { value = tonumber(value) }
end

--- True when a binding's visual state changed between two snapshots.
local function changed(binding: any, before: any, after: any): boolean
	if binding.kind == "growth" then
		return before.stage ~= after.stage
	elseif binding.kind == "health" then
		return before.value ~= after.value
	elseif binding.kind == "lamp" then
		return before.active ~= after.active
	elseif binding.kind == "outfit" then
		return before.worn ~= after.worn
	end
	return before.value ~= after.value
end

--- The floating-text line a change produces: a signed delta when the bound field
--- is a number, the declared label alone when the change is a state (a pad
--- lighting, an outfit going on, a crop ripening).
local function popupText(binding: any, before: any, after: any): string?
	local label = if type(binding.label) == "string" and #binding.label > 0 then binding.label else nil
	if label == nil then
		return nil
	end
	if binding.kind == "growth" then
		return if after.stage > before.stage then label else nil
	elseif binding.kind == "health" then
		local delta = after.value - before.value
		if delta == 0 then
			return nil
		end
		return string.format("%s %s%d", label, if delta > 0 then "+" else "-", math.abs(delta))
	elseif binding.kind == "lamp" or binding.kind == "outfit" then
		return if after.active == true or after.worn == true then label else nil
	end
	local delta = (after.value or 0) - (before.value or 0)
	if delta == 0 then
		return nil
	end
	return string.format("%s %s%d", label, if delta > 0 then "+" else "-", math.abs(delta))
end

--- Every node reaction between two snapshots: one row per binding whose visual
--- state changed, with the floating-text line and the cue the spec binds.
function M.deltas(world: any, before: any, after: any): { any }
	local out: { any } = {}
	if type(before) ~= "table" or type(after) ~= "table" then
		return out
	end
	for _, binding in M.bindings(world) do
		local previous = M.state(binding, before)
		local next_ = M.state(binding, after)
		if changed(binding, previous, next_) then
			table.insert(out, {
				nodeId = binding.nodeId,
				kind = binding.kind,
				field = binding.field,
				label = binding.label,
				cue = binding.cue,
				text = popupText(binding, previous, next_),
				before = previous,
				after = next_,
			})
		end
	end
	return out
end

--- The nodes that carry feedback, so the runtime knows which parts to address.
function M.nodes(world: any): { any }
	local out: { any } = {}
	local seen: { [string]: boolean } = {}
	for _, binding in M.bindings(world) do
		if not seen[binding.nodeId] then
			seen[binding.nodeId] = true
			table.insert(out, { id = binding.nodeId, kind = binding.nodeKind })
		end
	end
	return out
end

--- True for a snapshot field path: one segment, or dot-separated segments
--- (`balance`, `plots.1`, `activeBosses.slime`).
local function isFieldPath(value: any): boolean
	if type(value) ~= "string" or #value == 0 then
		return false
	end
	return string.find(value, "^[%a][%w_%-]*$") ~= nil or string.find(value, "^[%a][%w_%-]*%.[%w_%-%.]*[%w_%-]$") ~= nil
end

--- Every structural violation in the world's feedback declarations, sorted. The
--- spec validator calls this so a malformed binding fails `discover` rather than
--- rendering nothing at runtime.
function M.violations(world: any, cueKeys: { [string]: boolean }?): { string }
	local errors: { string } = {}
	local nodes = if type(world) == "table" and type(world.nodes) == "table" then world.nodes else {}
	for index, node in nodes do
		if type(node) ~= "table" or node.feedback == nil then
			continue
		end
		local label = string.format("world.nodes[%d].feedback", index)
		if type(node.feedback) ~= "table" or #node.feedback == 0 then
			table.insert(errors, label .. ": expected a nonempty list")
			continue
		end
		for entryIndex, entry in node.feedback do
			local where = string.format("%s[%d]", label, entryIndex)
			if type(entry) ~= "table" then
				table.insert(errors, where .. ": expected a mapping")
				continue
			end
			if type(entry.kind) ~= "string" or not KIND_SET[entry.kind] then
				table.insert(
					errors,
					where .. ".kind: expected one of " .. table.concat(M.KINDS, "|") .. ", got " .. tostring(entry.kind)
				)
			end
			if not isFieldPath(entry.field) then
				table.insert(errors, where .. ".field: expected a dotted snapshot path")
			end
			if type(entry.label) ~= "string" or #entry.label == 0 then
				table.insert(errors, where .. ".label: expected the floating-text copy")
			end
			if entry.kind == "outfit" and type(entry.entity) ~= "string" then
				table.insert(errors, where .. ".entity: an outfit binding names the outfit it wears")
			end
			if entry.kind == "lamp" and entry.active == nil then
				table.insert(errors, where .. ".active: a lamp binding names the value it lights on")
			end
			if entry.kind == "health" and (type(entry.max) ~= "number" or entry.max <= 0 or entry.max % 1 ~= 0) then
				table.insert(errors, where .. ".max: a health binding declares its full-health integer")
			end
			if entry.cue ~= nil then
				if type(entry.cue) ~= "string" then
					table.insert(errors, where .. ".cue: expected a cue key")
				elseif cueKeys ~= nil and not cueKeys[entry.cue] then
					table.insert(errors, where .. ".cue: undeclared cue " .. entry.cue)
				end
			end
		end
	end
	table.sort(errors)
	return errors
end

return M
