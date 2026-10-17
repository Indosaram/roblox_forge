--!strict
-- Registry of client panels for survival-coop extensions. Each factory receives
-- the shared UI kit, a durable `send`, a snapshot subscription delivering
-- snapshot.survivalExtensions, and the locale; it returns { destroy }.
-- Packs only call `start`; panel code lives in this genre.
local CommandTransport = require("../../../core/infra/genre/CommandTransport")

export type Context = {
	ui: any,
	locale: string,
	send: (string, { any }) -> any,
	-- The listener gets snapshot.survivalExtensions and, second, the whole packet
	-- (snapshots, roster, ...) for panels that also read another snapshot slice.
	onSnapshot: (({ [string]: any }, { [string]: any }) -> ()) -> () -> (),
}
export type Panel = { destroy: () -> () }
export type Factory = (Context) -> Panel?

local M = {}
M.factories = {
	-- Append panel factories here (one require of ./<Name>Panel per line, then .factory).
	require("./ContractsPanel").factory,
	require("./TamingPanel").factory,
	require("./CampPanel").factory,
	require("./ShopPanel").factory,
	require("./MarketPanel").factory,
	require("./DeathZonePanel").factory,
} :: { Factory }

function M.start(options: { ui: any, locale: string, factories: { Factory }? }): Panel
	local storage = game:GetService("ReplicatedStorage")
	local http = game:GetService("HttpService")
	local action = storage:WaitForChild("ForgeAction") :: RemoteFunction
	local state = storage:WaitForChild("ForgeState") :: RemoteEvent
	local durable: any = nil
	local latest: { [string]: any } = {}
	local latestPacket: { [string]: any } = {}
	local listeners: { [number]: ({ [string]: any }, { [string]: any }) -> () } = {}
	local nextListener = 0
	local pending: { [string]: any } = {}
	local connection = state.OnClientEvent:Connect(function(packet)
		if type(packet) ~= "table" then
			return
		end
		if packet.durable then
			durable = packet.durable
		end
		if type(packet.snapshots) == "table" then
			latest = packet.snapshots.survivalExtensions or {}
			latestPacket = packet
			for _, listener in listeners do
				task.spawn(listener, latest, latestPacket)
			end
		end
	end)
	local context: Context = {
		ui = options.ui,
		locale = options.locale,
		send = function(actionId, args)
			local epoch = if durable and durable.epochs then durable.epochs[actionId] else nil
			if not CommandTransport.durable(durable, actionId) or (pending[actionId] == nil and epoch == nil) then
				return { ok = false, reason = "COMMAND_UNAVAILABLE" }
			end
			pending[actionId] = CommandTransport.request(pending[actionId], actionId, args, epoch, function()
				return http:GenerateGUID(false)
			end)
			local ok, result = pcall(function()
				return action:InvokeServer("command", pending[actionId])
			end)
			if not ok then
				return { ok = false, reason = "TRANSPORT_FAILED: " .. tostring(result) }
			end
			pending[actionId] = CommandTransport.settle(pending[actionId], result)
			return result
		end,
		onSnapshot = function(callback)
			nextListener += 1
			local key = nextListener
			listeners[key] = callback
			task.spawn(callback, latest, latestPacket)
			return function()
				listeners[key] = nil
			end
		end,
	}
	local panels: { Panel } = {}
	for _, factory in options.factories or M.factories do
		local panel = factory(context)
		if panel then
			table.insert(panels, panel)
		end
	end
	local destroyed = false
	return {
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			connection:Disconnect()
			table.clear(listeners)
			for _, panel in panels do
				panel.destroy()
			end
		end,
	}
end
return M
