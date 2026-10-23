--!strict
-- Registers the farming and crafting screens on the shared dock: farm plot, sprayer,
-- crop book, crop specialization, processing, recipe preview and inbox. One snapshot
-- subscription feeds every sheet; `hub.open` switches between them.
local M = {}
local env: any = getfenv()
local Text = require("./FarmCraftText")
M.screens = {
	farm = require("./FarmPlotPanel"),
	["farm-area"] = require("./FarmAreaPanel"),
	["crop-book"] = require("./CropBookPanel"),
	["crop-specialize"] = require("./CropSpecializePanel"),
	processing = require("./ProcessingPanel"),
	["craft-preview"] = require("./CraftPreviewPanel"),
	inbox = require("./InboxPanel"),
}
M.ORDER = { "farm", "farm-area", "crop-book", "crop-specialize", "processing", "craft-preview", "inbox" }

function M.mount(ctx: any, hub: any): any
	local sheets: { [string]: any } = {}
	hub.state = hub.state or {}
	hub.name = hub.name
		or function(id: string): string
			return (ctx.names and ctx.names[id]) or Text.text(ctx.locale, id)
		end
	function hub.open(id: string)
		for other, sheet in sheets do
			if other ~= id then
				sheet.close()
			end
		end
		sheets[id].open()
	end
	for _, id in M.ORDER do
		sheets[id] = M.screens[id].mount(ctx, hub)
	end
	local unsubscribe = ctx.onSnapshot(function(extensions: any, packet: any)
		hub.state.home, hub.state.market, hub.state.packet = extensions.home, extensions.market, packet
		hub.state.expedition = extensions.expedition
		for _, sheet in sheets do
			sheet.render()
		end
	end)
	return {
		sheets = sheets,
		hub = hub,
		destroy = function()
			unsubscribe()
			for _, sheet in sheets do
				sheet.destroy()
			end
		end,
	}
end

-- Client factory: engine ports for time, the local actor and the nearest station.
function M.factory(ctx: any): any
	if not ctx.content then
		return nil
	end
	local game = env.game
	local players = game:GetService("Players")
	local tags = game:GetService("CollectionService")
	local workspace = game:GetService("Workspace")
	return M.mount(ctx, {
		content = ctx.content,
		now = function(): number
			return workspace:GetServerTimeNow()
		end,
		actor = function(): string
			return tostring(players.LocalPlayer.UserId)
		end,
		station = function(kind: string?): string
			local character = players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not kind or not root then
				return "hand"
			end
			local best, distance = "hand", 12
			for _, part in tags:GetTagged("ForgeSurvivalStation") do
				if part:IsA("BasePart") and part:GetAttribute("ForgeStationKind") == kind then
					local d = (part.Position - root.Position).Magnitude
					if d < distance then
						best, distance = part:GetAttribute("ForgeStationId"), d
					end
				end
			end
			return best
		end,
	})
end

return M
