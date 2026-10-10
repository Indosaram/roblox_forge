--!strict
local M = {}
export type Policy = {
	personal: { namespace: string, inventoryPath: { string } }?,
	actions: { string },
	serverActions: { string }?,
	tickAction: string?,
	windowSeconds: number?,
	maxOutcomes: number?,
}
export type Epoch = { createdAt: number, expiresAt: number, outcomes: { [string]: any } }
export type Ledger = { version: number, epoch: number, stateVersion: number, epochs: { [string]: Epoch } }
-- Trusted, validated ledger only. Use the same clock units as expiresAt and
-- compute after authoritative epoch rotation. A receipt may outlive acceptance.
-- No mutation: every epoch strictly below the result has no live window/receipt.
function M.retentionFloor(ledger: Ledger, now: number): number
	local floor = ledger.epoch + 1
	for id, epoch in ledger.epochs do
		local live = now < epoch.expiresAt
		if not live then
			for _, outcome in epoch.outcomes do
				if now < outcome.expiresAt then
					live = true
					break
				end
			end
		end
		if live then
			floor = math.min(floor, tonumber(id) :: number)
		end
	end
	return floor
end

function M.canonical(value: any): string
	if type(value) ~= "table" then
		return type(value) .. ":" .. string.format("%q", tostring(value))
	end
	local keys = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, key in keys do
		table.insert(parts, M.canonical(key) .. "=" .. M.canonical(value[key]))
	end
	return "{" .. table.concat(parts, ";") .. "}"
end
function M.valid(value: any, data: (any) -> boolean): boolean
	if
		type(value) ~= "table"
		or type(value.epoch) ~= "number"
		or value.epoch < 0
		or value.epoch % 1 ~= 0
		or type(value.stateVersion) ~= "number"
		or value.stateVersion < 0
		or value.stateVersion % 1 ~= 0
		or value.version ~= 2
		or type(value.epochs) ~= "table"
	then
		return false
	end
	for key in value do
		if key ~= "version" and key ~= "epoch" and key ~= "stateVersion" and key ~= "epochs" then
			return false
		end
	end
	local epochCount = 0
	if value.epochs[tostring(value.epoch)] == nil then
		return false
	end
	for epochId, epoch in value.epochs do
		epochCount += 1
		if
			epochCount > 2
			or type(epochId) ~= "string"
			or tonumber(epochId) == nil
			or type(epoch) ~= "table"
			or type(epoch.createdAt) ~= "number"
			or type(epoch.expiresAt) ~= "number"
			or epoch.expiresAt <= epoch.createdAt
			or not data({ epoch.createdAt, epoch.expiresAt })
			or type(epoch.outcomes) ~= "table"
			or epochId ~= tostring(tonumber(epochId))
			or (tonumber(epochId) :: number) % 1 ~= 0
			or (tonumber(epochId) :: number) < 0
			or (tonumber(epochId) :: number) > value.epoch
		then
			return false
		end
		for key in epoch do
			if key ~= "createdAt" and key ~= "expiresAt" and key ~= "outcomes" then
				return false
			end
		end
		local count = 0
		for id, outcome in epoch.outcomes do
			count += 1
			if
				count > 4096
				or not data(outcome)
				or type(id) ~= "string"
				or #id == 0
				or #id > 128
				or type(outcome) ~= "table"
				or type(outcome.binding) ~= "string"
				or type(outcome.result) ~= "table"
				or type(outcome.result.ok) ~= "boolean"
				or type(outcome.result.stateVersion) ~= "number"
				or type(outcome.createdAt) ~= "number"
				or type(outcome.expiresAt) ~= "number"
				or outcome.expiresAt <= outcome.createdAt
				or outcome.createdAt < epoch.createdAt
				or outcome.createdAt >= epoch.expiresAt
				or outcome.expiresAt ~= outcome.createdAt + (epoch.expiresAt - epoch.createdAt)
				or outcome.result.stateVersion % 1 ~= 0
				or outcome.result.stateVersion < 1
				or outcome.result.stateVersion > value.stateVersion
			then
				return false
			end
			for key in outcome do
				if key ~= "binding" and key ~= "result" and key ~= "createdAt" and key ~= "expiresAt" then
					return false
				end
			end
		end
	end
	return true
end
return M
