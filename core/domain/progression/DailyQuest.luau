--!strict
-- DailyQuest: day-indexed quest progress with one-time claims and daily rollover.

local SECONDS_PER_DAY = 86400

export type Quest = { id: string, target: number, reward: number }

export type State = {
	day: number,
	quests: { [string]: Quest },
	progress: { [string]: number },
	claimed: { [string]: boolean },
}

local DailyQuest = {}

local function checkFinite(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error("invalid " .. label)
	end
end

local function findQuest(state: State, questId: string): Quest
	if type(questId) ~= "string" or questId == "" then
		error("invalid quest id")
	end
	local quest: Quest? = state.quests[questId]
	if quest == nil then
		error("unknown quest: " .. questId)
	end
	return quest :: Quest
end

function DailyQuest.dayIndex(unixSeconds: number): number
	checkFinite(unixSeconds, "unixSeconds")
	return math.floor(unixSeconds / SECONDS_PER_DAY)
end

function DailyQuest.new(day: number, quests: { Quest }): State
	checkFinite(day, "day")
	if day % 1 ~= 0 then
		error("invalid day")
	end
	local state: State = { day = day, quests = {}, progress = {}, claimed = {} }
	for _, quest in quests do
		if type(quest.id) ~= "string" or quest.id == "" then
			error("invalid quest id")
		end
		checkFinite(quest.target, "quest target")
		checkFinite(quest.reward, "quest reward")
		if quest.target < 0 or quest.target % 1 ~= 0 then
			error("invalid quest target")
		end
		if quest.reward <= 0 or quest.reward % 1 ~= 0 then
			error("invalid quest reward")
		end
		if state.quests[quest.id] ~= nil then
			error("duplicate quest id: " .. quest.id)
		end
		state.quests[quest.id] = { id = quest.id, target = quest.target, reward = quest.reward }
		state.progress[quest.id] = 0
		state.claimed[quest.id] = false
	end
	return state
end

function DailyQuest.record(state: State, questId: string, amount: number): ()
	local quest = findQuest(state, questId)
	checkFinite(amount, "amount")
	if amount < 0 then
		error("invalid amount")
	end
	local nextProgress = (state.progress[questId] or 0) + amount
	if nextProgress > quest.target then
		nextProgress = quest.target
	end
	state.progress[questId] = nextProgress
end

function DailyQuest.claim(state: State, questId: string): (boolean, number)
	local quest = findQuest(state, questId)
	if state.claimed[questId] then
		return false, 0
	end
	if (state.progress[questId] or 0) < quest.target then
		return false, 0
	end
	state.claimed[questId] = true
	return true, quest.reward
end

function DailyQuest.rollover(state: State, today: number, quests: { Quest }): State
	checkFinite(today, "today")
	if today > state.day then
		return DailyQuest.new(today, quests)
	end
	return state
end

return DailyQuest
