--!strict
-- Quests: requirement-tracked quests with one-time reward claims for
-- rpg-progression games. A quest completes when every requirement reaches its
-- count; claim pays the reward exactly once.

export type Requirement = {
	kind: string,
	target: string,
	count: number,
}

export type Reward = {
	coins: number?,
	xp: number?,
}

export type QuestDef = {
	id: string,
	requirements: { Requirement },
	reward: Reward,
}

export type State = {
	order: { string },
	quests: { [string]: QuestDef },
	progress: { [string]: { number } },
	claimed: { [string]: boolean },
}

export type Event = {
	kind: string,
	target: string,
	count: number,
}

local Quests = {}

local function checkName(value: string, label: string): ()
	if type(value) ~= "string" or value == "" then
		error("invalid " .. label)
	end
end

local function checkCount(value: number, label: string): ()
	if type(value) ~= "number" or value ~= value or value == math.huge or value % 1 ~= 0 then
		error("invalid " .. label)
	end
end

local function checkReward(reward: Reward): ()
	if type(reward) ~= "table" then
		error("invalid reward")
	end
	if reward.coins ~= nil and (type(reward.coins) ~= "number" or reward.coins ~= reward.coins or reward.coins < 0) then
		error("invalid reward coins")
	end
	if reward.xp ~= nil and (type(reward.xp) ~= "number" or reward.xp ~= reward.xp or reward.xp < 0) then
		error("invalid reward xp")
	end
end

local function findQuest(state: State, questId: string): QuestDef
	checkName(questId, "quest id")
	local quest: QuestDef? = state.quests[questId]
	if quest == nil then
		error("unknown quest: " .. questId)
	end
	return quest
end

function Quests.new(defs: { QuestDef }): State
	if type(defs) ~= "table" then
		error("invalid quest defs")
	end
	local state: State = { order = {}, quests = {}, progress = {}, claimed = {} }
	for _, def in defs do
		if type(def) ~= "table" then
			error("invalid quest def")
		end
		checkName(def.id, "quest id")
		if state.quests[def.id] ~= nil then
			error("duplicate quest id: " .. def.id)
		end
		if type(def.requirements) ~= "table" or #def.requirements == 0 then
			error("invalid quest requirements")
		end
		local requirements: { Requirement } = {}
		local zero: { number } = {}
		for index, requirement in def.requirements do
			checkName(requirement.kind, "requirement kind")
			checkName(requirement.target, "requirement target")
			checkCount(requirement.count, "requirement count")
			if requirement.count < 1 then
				error("invalid requirement count")
			end
			requirements[index] = {
				kind = requirement.kind,
				target = requirement.target,
				count = requirement.count,
			}
			zero[index] = 0
		end
		checkReward(def.reward)
		state.quests[def.id] = { id = def.id, requirements = requirements, reward = def.reward }
		state.progress[def.id] = zero
		state.claimed[def.id] = false
		table.insert(state.order, def.id)
	end
	return state
end

function Quests.isComplete(state: State, questId: string): boolean
	local quest = findQuest(state, questId)
	local progress = state.progress[questId]
	for index, requirement in quest.requirements do
		if progress[index] < requirement.count then
			return false
		end
	end
	return true
end

-- Records an event against every unclaimed quest that matches (kind, target).
-- Returns the ids this event completed for the first time, in definition order.
function Quests.progress(state: State, event: Event): { string }
	if type(event) ~= "table" then
		error("invalid event")
	end
	checkName(event.kind, "event kind")
	checkName(event.target, "event target")
	checkCount(event.count, "event count")
	if event.count < 0 then
		error("invalid event count")
	end

	local completed: { string } = {}
	for _, questId in state.order do
		if not state.claimed[questId] then
			local wasComplete = Quests.isComplete(state, questId)
			local quest = state.quests[questId]
			local progress = state.progress[questId]
			for index, requirement in quest.requirements do
				if requirement.kind == event.kind and requirement.target == event.target then
					local nextProgress = progress[index] + event.count
					if nextProgress > requirement.count then
						nextProgress = requirement.count
					end
					progress[index] = nextProgress
				end
			end
			if not wasComplete and Quests.isComplete(state, questId) then
				table.insert(completed, questId)
			end
		end
	end
	return completed
end

-- Pays the reward on the first claim of a completed quest; later claims (and
-- claims made before completion) return nil.
function Quests.claim(state: State, questId: string): Reward?
	local quest = findQuest(state, questId)
	if state.claimed[questId] or not Quests.isComplete(state, questId) then
		return nil
	end
	state.claimed[questId] = true
	return quest.reward
end

return Quests
