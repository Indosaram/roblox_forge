--!strict
-- D2 F2 server spawn gate. The place ships Players.CharacterAutoLoads = false (default.project.json),
-- so the engine never drops a character at (0, y, 0) while the role world is still building (2 of 3
-- cold starts fell to Y~-520 and waited out RespawnTime 270 = the C6 down hold). This gate:
--   * loads each character only once `ready()` (the role's ground under the spawn is written),
--     seated on the spawn part;
--   * reloads a character that died outside the C6 down flow (durable health still above 0) after
--     RESPAWN_SECONDS; a downed actor (durable health 0) is left to SurvivalWorld's down hold;
--   * returns a root that drops below VOID_Y to the spawn instead of letting the engine destroy it
--     at workspace.FallenPartsDestroyHeight (-500).
-- Every engine object arrives through `ports`, so specs drive it headless.
local M = {}

M.VOID_Y = -200
M.RESPAWN_SECONDS = 5
M.LIFT = 4

export type Ports = {
	players: any,
	heartbeat: any,
	spawn: any,
	ready: () -> boolean,
	-- Durable "alive" fact (health above 0, or no profile yet); false hands the death to the down hold.
	alive: (actor: string) -> boolean,
	delay: (seconds: number, fn: () -> ()) -> (),
}

function M.start(ports: Ports): { destroy: () -> () }
	local connections: { any } = {}
	local waiting: { [any]: boolean } = {}
	local stopped = false
	local function seat(player: any)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if character and root then
			character:PivotTo(ports.spawn.CFrame + Vector3.new(0, M.LIFT, 0))
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end
	local function load(player: any)
		if stopped or player.Parent == nil then
			return
		end
		player.RespawnLocation = ports.spawn
		player:LoadCharacterAsync()
		seat(player)
	end
	local function watch(player: any)
		table.insert(
			connections,
			player.CharacterAdded:Connect(function(character: any)
				local humanoid = character:WaitForChild("Humanoid")
				table.insert(
					connections,
					humanoid.Died:Connect(function()
						ports.delay(M.RESPAWN_SECONDS, function()
							-- Another path (the down hold's respawn) already reloaded: leave it.
							if player.Character == character and ports.alive(tostring(player.UserId)) then
								load(player)
							end
						end)
					end)
				)
			end)
		)
		if player.Character == nil then
			waiting[player] = true
		end
	end
	table.insert(connections, ports.players.PlayerAdded:Connect(watch))
	table.insert(
		connections,
		ports.players.PlayerRemoving:Connect(function(player: any)
			waiting[player] = nil
		end)
	)
	for _, player in ports.players:GetPlayers() do
		watch(player)
	end
	table.insert(
		connections,
		ports.heartbeat:Connect(function()
			if not ports.ready() then
				return
			end
			for player in waiting do
				waiting[player] = nil
				task.spawn(load, player)
			end
			for _, player in ports.players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if root and root.Position.Y < M.VOID_Y then
					seat(player)
				end
			end
		end)
	)
	return {
		destroy = function()
			stopped = true
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(waiting)
		end,
	}
end

return M
