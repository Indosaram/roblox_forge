--!strict
-- GrowHarvest: plot planting, timed growth, harvest, and sale for grow-harvest games.

local HatchTimer = require("../../../core/domain/progression/HatchTimer")
local Wallet = require("../../../core/domain/economy/Wallet")

export type CropConfig = {
	growthSeconds: number,
	sellPrice: number,
}

export type Config = {
	crops: { [string]: CropConfig },
	plotCount: number,
	currency: string?,
	startingBalance: number?,
}

export type PlotContext = {
	plot: number,
	cropId: string,
	now: number,
}

export type Hooks = {
	OnPlant: ((context: PlotContext) -> ())?,
	OnHarvest: ((context: PlotContext) -> ())?,
}

type Plot = {
	cropId: string,
	timer: HatchTimer.Timer,
}

local GrowHarvest = {}
GrowHarvest.__index = GrowHarvest

export type GrowHarvest = typeof(setmetatable(
	{} :: {
		_config: Config,
		_hooks: Hooks,
		_currency: string,
		_plots: { Plot? },
		wallet: Wallet.Wallet,
	},
	GrowHarvest
))

local function isValidPlot(config: Config, plotIndex: number): boolean
	return plotIndex % 1 == 0 and plotIndex >= 1 and plotIndex <= config.plotCount
end

function GrowHarvest.new(config: Config, hooks: Hooks?): GrowHarvest
	local self = setmetatable({
		_config = config,
		_hooks = hooks or {},
		_currency = config.currency or "Coins",
		_plots = {} :: { Plot? },
		wallet = Wallet.new(),
	}, GrowHarvest)
	if config.startingBalance ~= nil and config.startingBalance > 0 then
		self.wallet:credit(self._currency, config.startingBalance)
	end
	return self
end

function GrowHarvest.plant(self: GrowHarvest, plotIndex: number, cropId: string, now: number): boolean
	local crop = self._config.crops[cropId]
	if crop == nil or not isValidPlot(self._config, plotIndex) or self._plots[plotIndex] ~= nil then
		return false
	end
	self._plots[plotIndex] = { cropId = cropId, timer = HatchTimer.start(now, crop.growthSeconds) }
	local onPlant = self._hooks.OnPlant
	if onPlant ~= nil then
		onPlant({ plot = plotIndex, cropId = cropId, now = now })
	end
	return true
end

function GrowHarvest.harvest(self: GrowHarvest, plotIndex: number, now: number): string?
	if not isValidPlot(self._config, plotIndex) then
		return nil
	end
	local plot = self._plots[plotIndex]
	if plot == nil or not HatchTimer.isReady(plot.timer, now) then
		return nil
	end
	self._plots[plotIndex] = nil
	local onHarvest = self._hooks.OnHarvest
	if onHarvest ~= nil then
		onHarvest({ plot = plotIndex, cropId = plot.cropId, now = now })
	end
	return plot.cropId
end

function GrowHarvest.sell(self: GrowHarvest, cropId: string): number
	local crop = self._config.crops[cropId]
	if crop == nil then
		error("unknown crop")
	end
	if crop.sellPrice > 0 then
		self.wallet:credit(self._currency, crop.sellPrice)
	end
	return crop.sellPrice
end

function GrowHarvest.balance(self: GrowHarvest): number
	return self.wallet:balance(self._currency)
end

function GrowHarvest.cropAt(self: GrowHarvest, plotIndex: number): string?
	local plot = self._plots[plotIndex]
	return if plot ~= nil then plot.cropId else nil
end

function GrowHarvest.isReady(self: GrowHarvest, plotIndex: number, now: number): boolean
	local plot = self._plots[plotIndex]
	return plot ~= nil and HatchTimer.isReady(plot.timer, now)
end

function GrowHarvest.remaining(self: GrowHarvest, plotIndex: number, now: number): number
	local plot = self._plots[plotIndex]
	return if plot ~= nil then HatchTimer.remaining(plot.timer, now) else 0
end

-- Marks every planted crop ready immediately; used by Studio-only debug tooling.
function GrowHarvest.readyAll(self: GrowHarvest, now: number): ()
	for index, plot in self._plots do
		if plot ~= nil then
			self._plots[index] = { cropId = plot.cropId, timer = HatchTimer.start(now, 0) }
		end
	end
end

return GrowHarvest
