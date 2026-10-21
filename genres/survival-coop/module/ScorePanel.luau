--!strict
-- Engine-free score workspace controller. The renderer and audio scheduler are injected.
-- playAt must schedule against Workspace:GetServerTimeNow(), never packet receipt time.
local Score = require("../../../core/domain/music/Score")
local M = {}

function M.new(ctx: any): any
	local draft: any = nil
	local dirty = false
	local lastStart: number? = nil
	local api = {}
	function api.import(text: string): (boolean, string?)
		local value, reason = Score.import(text, ctx.rules, ctx.decode)
		if not value then
			return false, reason
		end
		draft = value
		dirty = true
		ctx.render(Score.copy(draft), dirty)
		return true, nil
	end
	function api.edit(part: number, note: number, replacement: any): (boolean, string?)
		if not draft or not draft.parts[part] then
			return false, "score.part"
		end
		local changed = Score.copy(draft)
		if note < 1 or note % 1 ~= 0 or note > #changed.parts[part].notes + 1 then
			return false, "score.note"
		end
		changed.parts[part].notes[note] = Score.copy(replacement)
		local value, reason = Score.validate(changed, ctx.rules)
		if not value then
			return false, reason
		end
		draft = value
		dirty = true
		ctx.render(Score.copy(draft), dirty)
		return true, nil
	end
	function api.tempo(tempo: number): (boolean, string?)
		if not draft then
			return false, "score.empty"
		end
		local changed = Score.copy(draft)
		changed.tempo = tempo
		local value, reason = Score.validate(changed, ctx.rules)
		if not value then
			return false, reason
		end
		draft = value
		dirty = true
		ctx.render(Score.copy(draft), dirty)
		return true, nil
	end
	function api.save(scoreId: string?): any
		if not draft then
			return { ok = false, reason = "score.empty" }
		end
		local args: { any } = { ctx.encode(draft), scoreId or "" }
		local result = ctx.send("survival-coop:score-import", args)
		if result.ok then
			dirty = false
			ctx.render(Score.copy(draft), dirty)
		end
		return result
	end
	function api.share(scoreId: string, revision: number, recipient: string): any
		local args: { any } = { scoreId, revision, recipient }
		return ctx.send("survival-coop:score-share", args)
	end
	function api.close(): boolean
		return not dirty or ctx.confirmDiscard()
	end
	function api.snapshot(value: any)
		local room = value.ensemble and value.ensemble.room
		if not room or not room.startAt or room.startAt == lastStart then
			return
		end
		lastStart = room.startAt
		for _, event in room.events do
			-- Late joins skip finished notes; retained future absolute times preserve sync.
			if event.untilAt > ctx.serverNow() then
				ctx.playAt(Score.copy(event), ctx.rules.instruments[event.instrumentId])
			end
		end
	end
	function api.preview(instrumentId: string, pitch: number, velocity: number): boolean
		local instrument = ctx.rules.instruments[instrumentId]
		if
			not instrument
			or pitch < ctx.rules.pitchMin
			or pitch > ctx.rules.pitchMax
			or pitch % 1 ~= 0
			or velocity < ctx.rules.velocityMin
			or velocity > ctx.rules.velocityMax
			or velocity % 1 ~= 0
		then
			return false
		end
		ctx.preview(instrument, pitch, velocity)
		return true
	end
	return api
end

return M
