--!strict
-- V2 companion candidate reducer. Publish companion + resources + receipt in
-- ONE owning aggregate transaction. No irreversible work happens in callbacks.
local M = {}
export type Pet = {
	id: string,
	species: string,
	phase: string,
	satiety: number,
	feeds: number,
	readyAt: number,
	cargo: number,
	injuredUntil: number,
	saddle: boolean,
	stamina: number,
}
export type State = {
	pets: { [string]: Pet },
	materials: { [string]: number },
	receipts: { [string]: string },
	deployed: string?,
	ride: string?,
	lastMillis: number,
}
export type Rules = {
	capacity: number,
	feedItem: string,
	feedCount: number,
	trainingMillis: number,
	maxSatiety: number,
	feedSatiety: number,
	hungerMillis: number,
	downMillis: number,
}
function M.new(materials: { [string]: number }, now: number): State
	for _, quantity in materials do
		assert(quantity >= 0 and quantity % 1 == 0, "INVALID_MATERIALS")
	end
	return { pets = {}, materials = table.clone(materials), receipts = {}, lastMillis = now }
end
local function copy(state: State): State
	local result = table.clone(state)
	result.pets, result.materials, result.receipts = {}, table.clone(state.materials), table.clone(state.receipts)
	for id, pet in state.pets do
		result.pets[id] = table.clone(pet)
	end
	return result
end
function M.capture(state: State, id: string, species: string, rules: Rules): (State?, string?)
	if state.pets[id] then
		return nil, "ALREADY_CAPTURED"
	end
	local count = 0
	for _ in state.pets do
		count += 1
	end
	if count >= rules.capacity then
		return nil, "CAPACITY"
	end
	local result = copy(state)
	result.pets[id] = {
		id = id,
		species = species,
		phase = "Captured",
		satiety = rules.maxSatiety,
		feeds = 0,
		readyAt = 0,
		cargo = 0,
		injuredUntil = 0,
		saddle = false,
		stamina = 100,
	}
	return result, nil
end
function M.command(
	state: State,
	request: string,
	action: string,
	id: string,
	now: number,
	rules: Rules
): (State?, string?)
	assert(now >= state.lastMillis and now % 1 == 0, "INVALID_CLOCK")
	local binding = action .. ":" .. id
	if state.receipts[request] then
		return if state.receipts[request] == binding then state else nil,
			if state.receipts[request] == binding then nil else "REQUEST_CONFLICT"
	end
	local pet = state.pets[id]
	if not pet then
		return nil, "NOT_OWNER"
	end
	local result = copy(state)
	local nextPet = result.pets[id]
	local function consume(): boolean
		local quantity = result.materials[rules.feedItem] or 0
		if quantity < 1 then
			return false
		end
		result.materials[rules.feedItem] = quantity - 1
		return true
	end
	if action == "place" then
		if pet.phase ~= "Captured" then
			return nil, "INVALID_PHASE"
		end
		nextPet.phase = "PenPlaced"
	elseif action == "train" then
		if pet.phase ~= "PenPlaced" then
			return nil, "INVALID_PHASE"
		end
		nextPet.phase, nextPet.readyAt = "Taming", now + rules.trainingMillis
	elseif action == "cancel" then
		if pet.phase ~= "Taming" then
			return nil, "INVALID_PHASE"
		end
		nextPet.phase, nextPet.feeds, nextPet.readyAt = "Captured", 0, 0
	elseif action == "feed" then
		if not consume() then
			return nil, "NO_FEED"
		end
		if pet.phase == "Taming" then
			nextPet.feeds += 1
		end
		nextPet.satiety = math.min(rules.maxSatiety, pet.satiety + rules.feedSatiety)
		if pet.phase == "Downed" then
			nextPet.phase, nextPet.injuredUntil = "Stored", 0
		end
	elseif action == "claim" then
		if pet.phase ~= "Taming" or pet.feeds < rules.feedCount or now < pet.readyAt then
			return nil, "NOT_READY"
		end
		nextPet.phase = "Stored"
	elseif action == "deploy" then
		if pet.phase ~= "Stored" or state.deployed then
			return nil, "DEPLOYMENT_LIMIT"
		end
		nextPet.phase, result.deployed = "Deployed", id
	elseif action == "recall" then
		if pet.phase ~= "Deployed" then
			return nil, "INVALID_PHASE"
		end
		nextPet.phase, result.deployed, result.ride = "Stored", nil, nil
	elseif action == "saddle" then
		if (result.materials.saddle or 0) < 1 then
			return nil, "NO_SADDLE"
		end
		if pet.saddle then
			return nil, "ALREADY_SADDLED"
		end
		result.materials.saddle -= 1
		nextPet.saddle = true
	elseif action == "mount" then
		if pet.phase ~= "Deployed" or not pet.saddle or pet.satiety <= 0 then
			return nil, "MOUNT_GATED"
		end
		result.ride = id
	elseif action == "dismount" then
		if state.ride ~= id then
			return nil, "NOT_MOUNTED"
		end
		result.ride = nil
	elseif action == "defeat" then
		if pet.phase ~= "Deployed" then
			return nil, "INVALID_PHASE"
		end
		nextPet.phase, nextPet.injuredUntil = "Downed", now + rules.downMillis
		result.ride, result.deployed = nil, nil
	elseif action == "recover" then
		if pet.phase ~= "Downed" or now < pet.injuredUntil then
			return nil, "NOT_READY"
		end
		nextPet.phase, nextPet.injuredUntil = "Stored", 0
	elseif action == "release:" .. id then
		if pet.phase ~= "Stored" and pet.phase ~= "Captured" then
			return nil, "RELEASE_PHASE"
		end
		if pet.cargo ~= 0 or pet.injuredUntil > now then
			return nil, "RELEASE_CARGO_OR_INJURY"
		end
		result.pets[id] = nil
	else
		return nil, "UNKNOWN_ACTION"
	end
	result.receipts[request] = binding
	result.lastMillis = now
	return result, nil
end
-- Online ticks only. Call after reconnect with lastMillis reset to join clock;
-- no offline hunger, no wall-clock read, and no hunger applied to stored pets.
function M.tick(state: State, now: number, rules: Rules): State
	assert(now >= state.lastMillis and now % 1 == 0, "INVALID_CLOCK")
	local result = copy(state)
	local minutes = (now - state.lastMillis) // rules.hungerMillis
	if minutes == 0 then
		return result
	end
	result.lastMillis += minutes * rules.hungerMillis
	if result.deployed then
		local pet = result.pets[result.deployed]
		pet.satiety = math.max(0, pet.satiety - minutes)
		if pet.satiety == 0 then
			result.ride = nil
		end
	end
	return result
end
return M
