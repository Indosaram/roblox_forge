--!strict
-- In-memory live ensemble; immutable score revisions are loaded/saved by the injected repository.
local Score = require("./Score")
local M = {}

function M.new(rules: any, ports: any): any
	local room: any = nil
	local api = {}
	function api.snapshot(): any
		return Score.copy(room)
	end
	function api.join(actor: string, scoreId: string, revision: number, part: number): (boolean, string?)
		if not ports.inRange(actor, rules.radiusStuds) then
			return false, "ensemble.range"
		end
		local saved = ports.load(scoreId, revision)
		if saved == nil then
			return false, "score.missing"
		end
		if type(part) ~= "number" or part % 1 ~= 0 or not saved.parts[part] then
			return false, "ensemble.part"
		end
		if room and (room.scoreId ~= scoreId or room.revision ~= revision) then
			return false, "ensemble.revision"
		end
		if room then
			local count = 0
			for _member in room.members do
				count += 1
			end
			if not room.members[actor] and count >= rules.maxPerformers then
				return false, "ensemble.full"
			end
			for member, assigned in room.members do
				if member ~= actor and assigned.part == part then
					return false, "ensemble.part_taken"
				end
			end
			if room.startAt and (not room.vacancies[actor] or room.vacancies[actor] ~= part) then
				return false, "ensemble.playing"
			end
		else
			room = {
				host = actor,
				scoreId = scoreId,
				revision = revision,
				score = Score.copy(saved),
				members = {},
				vacancies = {},
			}
		end
		room.members[actor] = { part = part, ready = false }
		room.vacancies[actor] = nil
		return true, nil
	end
	function api.ready(actor: string, ready: boolean): (boolean, string?)
		if not room or not room.members[actor] or room.startAt then
			return false, "ensemble.lobby"
		end
		if type(ready) ~= "boolean" then
			return false, "ensemble.ready"
		end
		room.members[actor].ready = ready
		return true, nil
	end
	function api.start(actor: string, now: number): (boolean, string?)
		if not room or room.host ~= actor or room.startAt then
			return false, "ensemble.host"
		end
		for member, assignment in room.members do
			if not assignment.ready or not ports.inRange(member, rules.radiusStuds) then
				return false, "ensemble.not_ready"
			end
		end
		room.startAt = now + rules.countdownSeconds
		room.events = Score.schedule(room.score, rules, room.startAt)
		return true, nil
	end
	function api.leave(actor: string): (boolean, string?)
		if not room or not room.members[actor] then
			return false, "ensemble.member"
		end
		room.vacancies[actor] = room.members[actor].part
		room.members[actor] = nil
		if next(room.members) == nil then
			room = nil
		elseif room.host == actor then
			local actors = {}
			for member in room.members do
				table.insert(actors, member)
			end
			table.sort(actors)
			room.host = actors[1]
		end
		return true, nil
	end
	function api.advance(now: number)
		if room and room.events then
			local finishAt = room.startAt
			for _, event in room.events do
				finishAt = math.max(finishAt, event.untilAt)
			end
			if now >= finishAt then
				room = nil
			end
		end
	end
	return api
end

return M
