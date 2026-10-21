--!strict
-- Untrusted score boundary. Parsing is injected so the same validator runs in Lune and Roblox.
local M = {}

function M.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = M.copy(child)
	end
	return result
end

local function integer(value: any, minimum: number, maximum: number): boolean
	return type(value) == "number" and value == value and value >= minimum and value <= maximum and value % 1 == 0
end

local function fields(value: any, allowed: { [string]: boolean }): boolean
	if type(value) ~= "table" then
		return false
	end
	for key in value do
		if not allowed[key] then
			return false
		end
	end
	return true
end

local function dense(value: any, maximum: number): boolean
	if type(value) ~= "table" or #value > maximum then
		return false
	end
	local count = 0
	for key in value do
		if not integer(key, 1, #value) then
			return false
		end
		count += 1
	end
	return count == #value
end

function M.validate(score: any, rules: any): (any?, string?)
	if not fields(score, { version = true, tempo = true, parts = true }) or score.version ~= 1 then
		return nil, "score.version"
	end
	if not integer(score.tempo, rules.tempoMin, rules.tempoMax) then
		return nil, "score.tempo"
	end
	if not dense(score.parts, rules.maxParts) or #score.parts == 0 then
		return nil, "score.parts"
	end
	local maxTick = rules.maxDurationSeconds * score.tempo * rules.ticksPerQuarter / 60
	for partIndex, part in score.parts do
		local path = "score.parts[" .. tostring(partIndex) .. "]"
		if not fields(part, { instrumentId = true, notes = true }) or not rules.instruments[part.instrumentId] then
			return nil, path .. ".instrumentId"
		end
		if not dense(part.notes, rules.maxNotesPerPart) then
			return nil, path .. ".notes"
		end
		local events = {}
		for noteIndex, note in part.notes do
			local notePath = path .. ".notes[" .. tostring(noteIndex) .. "]"
			if not fields(note, { startTick = true, durationTicks = true, pitch = true, velocity = true }) then
				return nil, notePath
			end
			if not integer(note.startTick, 0, maxTick) then
				return nil, notePath .. ".startTick"
			end
			if not integer(note.durationTicks, 1, maxTick) or note.startTick + note.durationTicks > maxTick then
				return nil, notePath .. ".durationTicks"
			end
			if not integer(note.pitch, rules.pitchMin, rules.pitchMax) then
				return nil, notePath .. ".pitch"
			end
			if not integer(note.velocity, rules.velocityMin, rules.velocityMax) then
				return nil, notePath .. ".velocity"
			end
			table.insert(events, { tick = note.startTick, delta = 1 })
			table.insert(events, { tick = note.startTick + note.durationTicks, delta = -1 })
		end
		table.sort(events, function(a, b)
			return a.tick < b.tick or (a.tick == b.tick and a.delta < b.delta)
		end)
		local voices = 0
		for _, event in events do
			voices += event.delta
			if voices > rules.maxPolyphony then
				return nil, path .. ".polyphony"
			end
		end
	end
	return M.copy(score), nil
end

function M.import(text: any, rules: any, decode: (string) -> any): (any?, string?)
	if type(text) ~= "string" or #text > rules.maxBytes then
		return nil, "score.bytes"
	end
	if utf8.len(text) == nil then
		return nil, "score.utf8"
	end
	local ok, value = pcall(decode, text)
	if not ok then
		return nil, "score.json"
	end
	return M.validate(value, rules)
end

-- Absolute server timestamps are identical for every client; network arrival never shifts a part.
function M.schedule(score: any, rules: any, startAt: number): { any }
	local events = {}
	local secondsPerTick = 60 / (score.tempo * rules.ticksPerQuarter)
	for partIndex, part in score.parts do
		for _, note in part.notes do
			table.insert(events, {
				part = partIndex,
				instrumentId = part.instrumentId,
				at = startAt + note.startTick * secondsPerTick,
				untilAt = startAt + (note.startTick + note.durationTicks) * secondsPerTick,
				pitch = note.pitch,
				velocity = note.velocity,
			})
		end
	end
	return events
end

return M
