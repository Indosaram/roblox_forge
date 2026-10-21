--!strict
-- All positions and instrument availability come from server Instances/venue registry.
-- Never accept a client-supplied distance, position, or venue ID as authority.
local M = {}
function M.new(config: any): any
	local api = {}
	function api.inRange(actor: string, radius: number): boolean
		local player = config.players:GetPlayerByUserId(tonumber(actor))
		local character = if player then player.Character else nil
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if not root or not humanoid or humanoid.Health <= 0 or not root:IsDescendantOf(config.workspace) then
			return false
		end
		for _, venue in config.venues() do
			if venue.enabled and venue.part:IsDescendantOf(config.workspace) and config.hasInstrument(actor, venue) then
				local delta = root.Position - venue.part.Position
				local squared = delta:Dot(delta)
				if squared == squared and squared <= radius * radius then
					return true
				end
			end
		end
		return false
	end
	function api.enforce(room: any, leave: (string) -> (), radius: number)
		if not room then
			return
		end
		for actor in room.members do
			if not api.inRange(actor, radius) then
				leave(actor)
			end
		end
	end
	return api
end
return M
