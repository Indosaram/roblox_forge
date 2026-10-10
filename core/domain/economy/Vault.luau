--!strict
-- Vault: an ordered egg list where a raid moves only raidable eggs, oldest first.

local Vault = {}

export type Egg = { id: string, raidable: boolean }
export type Vault = { _eggs: { Egg } }

local function checkEggId(eggId: string): ()
	if type(eggId) ~= "string" or eggId == "" then
		error("invalid egg id")
	end
end

function Vault.new(): Vault
	return { _eggs = {} }
end

function Vault.deposit(self: Vault, eggId: string, raidable: boolean): ()
	checkEggId(eggId)
	if type(raidable) ~= "boolean" then
		error("invalid raidable")
	end
	table.insert(self._eggs, { id = eggId, raidable = raidable })
end

function Vault.count(self: Vault, raidableOnly: boolean?): number
	if not raidableOnly then
		return #self._eggs
	end
	local total = 0
	for _, egg in self._eggs do
		if egg.raidable then
			total += 1
		end
	end
	return total
end

-- Moves up to maxTake raidable eggs from defender to attacker, oldest first.
-- Vaulted (raidable = false) eggs are never taken.
function Vault.raid(attacker: Vault, defender: Vault, maxTake: number): number
	if type(maxTake) ~= "number" or maxTake ~= maxTake then
		error("invalid maxTake")
	end
	if attacker == defender then
		return 0
	end
	local takeCap = math.floor(maxTake)
	if takeCap <= 0 then
		return 0
	end
	local kept: { Egg } = {}
	local moved = 0
	for _, egg in defender._eggs do
		if egg.raidable and moved < takeCap then
			table.insert(attacker._eggs, egg)
			moved += 1
		else
			table.insert(kept, egg)
		end
	end
	defender._eggs = kept
	return moved
end

return Vault
