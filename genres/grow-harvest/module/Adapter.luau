--!strict
local Contract = require("../../../core/domain/genre/Contract")
local GrowHarvest = require("./GrowHarvest")
local Schema = require("./Schema")
export type Config = Schema.Config
export type Planted = Schema.Planted
export type Save = Schema.Save
export type WalletPort = {
	balance: (Contract.PlayerId) -> number,
	debit: (Contract.PlayerId, number) -> boolean,
	credit: (Contract.PlayerId, number) -> (),
}
export type Instance = Contract.Instance & { walletPort: WalletPort }
type Player = {
	garden: GrowHarvest.GrowHarvest,
	seeds: { [string]: number },
	inventory: { [string]: number },
	plots: { [number]: Planted },
}
local Adapter = {}
local LIMIT = 1e9
Adapter.validateConfig = Schema.validateConfig
Adapter.validateSave = Schema.validateSave
local numeric = Schema.numeric
local function copy(source: { [string]: number }): { [string]: number }
	return table.clone(source)
end
function Adapter.create(data: Contract.ConfigData, services: Contract.Services): Instance
	local errors = Adapter.validateConfig(data)
	assert(#errors == 0, table.concat(errors, "; "))
	local config = Schema.copyConfig(data)
	local players: { [string]: Player } = {}
	local function emit(playerId: string, name: string, context: Contract.StateData)
		services.emit({ genre = "grow-harvest", name = name, playerId = playerId, data = context })
	end
	local function reject(reason: string): Contract.Result
		return { ok = false, reason = reason }
	end
	local instance = {} :: Instance
	function instance.join(playerId: string, saved: Contract.StateData?): Contract.Result
		if players[playerId] ~= nil then
			return reject("already joined")
		end
		local now = services.now()
		if not numeric(now, 0, 1e12, false) then
			return reject("invalid clock")
		end
		local state: Save =
			{ balance = config.startingBalance, seeds = copy(config.startingSeeds), inventory = {}, plots = {} }
		if saved ~= nil then
			local problems = Adapter.validateSave(saved)
			if #problems > 0 then
				return reject(table.concat(problems, "; "))
			end
			state = saved :: Save
			for k in state.seeds do
				if config.crops[k] == nil then
					return reject("unknown saved seed")
				end
			end
			for k in state.inventory do
				if config.crops[k] == nil then
					return reject("unknown saved inventory")
				end
			end
			for _, planted in state.plots do
				if
					planted.plot > config.plotCount
					or config.crops[planted.cropId] == nil
					or planted.plantedAt > now
				then
					return reject("invalid saved plot")
				end
			end
		end
		local nativeConfig: GrowHarvest.Config = {
			currency = config.currency,
			startingBalance = state.balance,
			plotCount = config.plotCount,
			crops = config.crops,
		}
		-- Public constructor restores wallet once; public plant restores absolute timers without hooks.
		local garden = GrowHarvest.new(nativeConfig)
		local plots: { [number]: Planted } = {}
		for _, planted in state.plots do
			assert(
				garden:plant(planted.plot, planted.cropId, planted.plantedAt),
				"expected garden:plant(planted.plot, planted.cropId, planted.plantedAt)"
			)
			plots[planted.plot] = { plot = planted.plot, cropId = planted.cropId, plantedAt = planted.plantedAt }
		end
		players[playerId] =
			{ garden = garden, seeds = copy(state.seeds), inventory = copy(state.inventory), plots = plots }
		return { ok = true }
	end
	function instance.leave(playerId: string): ()
		players[playerId] = nil
	end
	function instance.dispatch(playerId: string, action: string, args: { any }): Contract.Result
		local player = players[playerId]
		if player == nil then
			return reject("not joined")
		end
		local arity = if action == "plant"
			then 2
			elseif action == "buy-seed" or action == "harvest" or action == "sell-held" then 1
			else -1
		local n = 0
		for index in args do
			n += 1
			if not numeric(index, 1, arity, true) then
				return reject("invalid arguments")
			end
		end
		if n ~= arity then
			return reject("invalid arguments")
		end
		local now = services.now()
		if not numeric(now, 0, 1e12, false) then
			return reject("invalid clock")
		end
		if action == "buy-seed" or action == "sell-held" then
			local cropId = args[1]
			if type(cropId) ~= "string" or config.crops[cropId] == nil then
				return reject("unknown crop")
			end
			if action == "buy-seed" then
				local held = player.seeds[cropId] or 0
				if held >= LIMIT then
					return reject("seed limit")
				end
				local price = config.seedPrice[cropId]
				if not player.garden.wallet:debit(config.currency, price) then
					return reject("insufficient funds")
				end
				player.seeds[cropId] = held + 1
				emit(playerId, "SeedBought", { cropId = cropId, price = price })
			else
				local held = player.inventory[cropId] or 0
				local price = config.crops[cropId].sellPrice
				if held <= 0 then
					return reject("empty inventory")
				end
				if player.garden:balance() + price > LIMIT then
					return reject("balance limit")
				end
				player.inventory[cropId] = held - 1
				local paid = player.garden:sell(cropId)
				emit(playerId, "CropSold", { cropId = cropId, price = paid })
			end
		else
			local plot = args[1]
			if not numeric(plot, 1, config.plotCount, true) then
				return reject("invalid plot")
			end
			if action == "plant" then
				local cropId = args[2]
				if type(cropId) ~= "string" or config.crops[cropId] == nil then
					return reject("unknown crop")
				end
				local seeds = player.seeds[cropId] or 0
				if seeds <= 0 then
					return reject("no seeds")
				end
				if not player.garden:plant(plot, cropId, now) then
					return reject("occupied plot")
				end
				player.seeds[cropId] = seeds - 1
				player.plots[plot] = { plot = plot, cropId = cropId, plantedAt = now }
				emit(playerId, "OnPlant", { plot = plot, cropId = cropId, now = now })
			else
				local cropId = player.garden:cropAt(plot)
				if cropId == nil then
					return reject("empty plot")
				end
				if (player.inventory[cropId] or 0) >= LIMIT then
					return reject("inventory limit")
				end
				local harvested = player.garden:harvest(plot, now)
				if harvested == nil then
					return reject("not ready")
				end
				player.plots[plot] = nil
				player.inventory[harvested] = (player.inventory[harvested] or 0) + 1
				emit(playerId, "OnHarvest", { plot = plot, cropId = harvested, now = now })
			end
		end
		return { ok = true }
	end
	function instance.advance(_now: number): () end -- Native timers use absolute time, not accumulated ticks.
	function instance.save(playerId: string): Contract.StateData
		local player = players[playerId]
		assert(player ~= nil, "not joined")
		local plots: { Planted } = {}
		for plot = 1, config.plotCount do
			local planted = player.plots[plot]
			if planted ~= nil then
				table.insert(plots, { plot = plot, cropId = planted.cropId, plantedAt = planted.plantedAt })
			end
		end
		return {
			balance = player.garden:balance(),
			seeds = copy(player.seeds),
			inventory = copy(player.inventory),
			plots = plots,
		}
	end
	function instance.snapshot(playerId: string): Contract.StateData
		local player = players[playerId]
		assert(player ~= nil, "not joined")
		local now = services.now()
		local state = instance.save(playerId)
		local plots: { Contract.StateData } = {}
		for plot = 1, config.plotCount do
			local planted = player.plots[plot]
			table.insert(plots, {
				plot = plot,
				cropId = player.garden:cropAt(plot),
				ready = player.garden:isReady(plot, now),
				readyAt = if planted ~= nil
					then planted.plantedAt + config.crops[planted.cropId].growthSeconds
					else nil,
			})
		end
		state.plots = plots
		return state
	end
	instance.walletPort = {
		balance = function(playerId)
			local p = players[playerId]
			assert(p ~= nil, "not joined")
			return p.garden:balance()
		end,
		debit = function(playerId, amount)
			local p = players[playerId]
			if p == nil or not numeric(amount, 1, LIMIT, true) then
				return false
			end
			return p.garden.wallet:debit(config.currency, amount)
		end,
		credit = function(playerId, amount)
			local p = players[playerId]
			assert(p ~= nil, "not joined")
			assert(numeric(amount, 1, LIMIT, true) and p.garden:balance() + amount <= LIMIT, "invalid credit")
			p.garden.wallet:credit(config.currency, amount)
		end,
	}
	return instance
end
return Adapter
