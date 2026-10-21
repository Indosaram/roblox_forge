--!strict
-- Ownership transitions only. The caller commits the returned state before effects/acknowledgement.
local M = {}
export type State = {
	receipts: { [string]: string },
	skins: { [string]: boolean },
	passes: { [string]: boolean },
	subscription: { active: boolean, setId: string?, slots: number },
}
function M.new(): State
	return { receipts = {}, skins = {}, passes = {}, subscription = { active = false, slots = 0 } }
end
function M.copy(state: State): State
	return {
		receipts = table.clone(state.receipts),
		skins = table.clone(state.skins),
		passes = table.clone(state.passes),
		subscription = table.clone(state.subscription),
	}
end
function M.grant(state: State, receipt: string, key: string, skin: string): (State?, string?)
	local known = state.receipts[receipt]
	if known and known ~= key then
		return nil, "RECEIPT_CONFLICT"
	end
	local result = M.copy(state)
	result.receipts[receipt] = key
	result.skins[skin] = true
	return result, nil
end
function M.sync(state: State, passes: { [string]: boolean }, active: boolean, setId: string?, slots: number): State
	local result = M.copy(state)
	result.passes = table.clone(passes)
	result.subscription = { active = active, setId = setId, slots = slots }
	return result
end
function M.owns(state: State, skin: string): boolean
	return state.skins[skin] == true or (state.subscription.active and state.subscription.setId == skin)
end
function M.bonus(state: State, listings: { any }): number
	local slots = if state.subscription.active then state.subscription.slots else 0
	for _, listing in listings do
		if state.passes[listing.key] and listing.grant.kind == "storageSlots" then
			slots += listing.grant.amount
		end
	end
	return slots
end
return M
