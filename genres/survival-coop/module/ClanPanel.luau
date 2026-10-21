--!strict
local Clan = require("../../../core/domain/settlement/Clan")
local M = {}

function M.bounds(width: number, height: number): any
	local mobile = width < 700
	local w, h = math.min(if mobile then 344 else 896, width - 16), math.min(584, height - 56)
	return { x = (width - w) / 2, y = 48, width = w, height = h, rowHeight = 48, gap = 8 }
end

function M.model(state: any, actor: string, operations: { any }): any
	local rows = {}
	local govern = Clan.allowed(state, actor, "govern")
	for id, member in state.members do
		table.insert(rows, {
			id = id,
			text = id .. " / " .. member.role,
			role = member.role,
			withdraw = member.withdraw,
			canManage = govern and id ~= state.owner,
		})
	end
	table.sort(rows, function(a: any, b: any): boolean
		return a.id < b.id
	end)
	local research = {}
	for _, definition in operations do
		if definition.kind == "clan-research" then
			table.insert(research, {
				id = definition.id,
				cost = definition.cost,
				canStart = Clan.allowed(state, actor, "research")
					and state.level >= definition.gates.clanLevel
					and state.funds >= definition.cost,
			})
		end
	end
	return { members = rows, research = research, canInvite = Clan.allowed(state, actor, "invite"), govern = govern }
end

-- Shared actual Instance renderer; injected widgets permit service-free deterministic specs.
function M.mount(ctx: any, id: string, title: string, iconKey: string, render: any): any
	local env: any = getfenv()
	local ui = ctx.ui.components
	local theme = ctx.ui.theme.default
	local gui = (ctx.instance or env.Instance).new("ScreenGui")
	gui.Name, gui.ResetOnSpawn = id .. "Panel", false
	if env.Enum then
		gui.ZIndexBehavior = env.Enum.ZIndexBehavior.Sibling
	end
	gui.Parent = ctx.playerGui or env.game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	local sheet = ui.modalSheet(theme, { name = id, title = title })
	sheet.frame.Parent = gui
	local function fit(width: number, height: number)
		local bounds = M.bounds(width, height)
		local dim = ctx.udim2 or env.UDim2
		sheet.frame.Size = dim.fromOffset(bounds.width, bounds.height)
		sheet.frame.Position = dim.fromOffset(bounds.x, bounds.y)
		sheet.frame.AnchorPoint = (ctx.vector2 or env.Vector2).new(0, 0)
	end
	local unfit = if ctx.fitSheet then function() end else ctx.onViewport(fit)
	if ctx.fitSheet then
		ctx.fitSheet(sheet.frame)
	end
	sheet.close.Activated:Connect(function()
		sheet.frame.Visible = false
	end)
	ctx.dock({
		id = id,
		label = title,
		icon = ctx.icons.ui(iconKey),
		order = if id == "clan" then 7 else 8,
		setOpen = function(open: boolean)
			sheet.frame.Visible = open
		end,
		isOpen = function(): boolean
			return sheet.frame.Visible
		end,
	})
	local order = 0
	local rendered: string? = nil
	local function add(text: string, action: any?)
		order += 1
		local props = {
			text = text,
			size = (ctx.udim2 or env.UDim2).new(1, -16, 0, 48),
			parent = sheet.scroll,
			onClick = action,
		}
		local widget = if action then ui.button(theme, props) else ui.label(theme, props)
		widget.LayoutOrder, widget.TextWrapped = order, true
	end
	local function empty()
		if id == "clan" then
			add(ctx.text("clan.empty"))
			add(ctx.text("clan.create"), ctx.openMembership)
			add(ctx.text("clan.join"), ctx.openMembership)
		end
	end
	empty()
	local unsubscribe = ctx.onSnapshot(function(snapshot: any)
		local state = snapshot[id]
		local key = ctx.encode(state)
		if key == rendered then
			return
		end
		rendered = key
		for _, child in sheet.scroll:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
		order = 0
		if state then
			render(state, add)
		else
			empty()
		end
	end)
	return {
		destroy = function()
			unfit()
			unsubscribe()
			gui:Destroy()
		end,
	}
end

function M.factory(ctx: any): any
	return M.mount(ctx, "clan", ctx.text("ui.clan"), "social", function(state: any, add: any)
		local view = M.model(state, ctx.actorId, ctx.content.operations)
		local function command(operation: string, args: any)
			args.expectedRevision = state.revision
			return ctx.send("survival-coop:clan-" .. operation, { state.clanId, args })
		end
		add(ctx.text("clan.level") .. ": " .. state.level .. " / " .. state.funds)
		add(ctx.text("clan.territory") .. ": " .. state.territory)
		if ctx.openOutposts then
			add(ctx.text("ui.outpost"), ctx.openOutposts)
		end
		for _, row in view.members do
			add(row.text)
			if row.canManage then
				add(ctx.text("clan.officer"), function()
					command("role", { target = row.id, role = "officer" })
				end)
				add(ctx.text("clan.member"), function()
					command("role", { target = row.id, role = "member" })
				end)
				add(ctx.text("clan.withdraw-permission"), function()
					command("capability", { target = row.id, enabled = not row.withdraw })
				end)
				add(ctx.text("clan.transfer"), function()
					if ctx.confirm("clan.transfer", row.id) then
						command("transfer", { target = row.id })
					end
				end)
			end
		end
		if view.canInvite then
			add(ctx.text("clan.invite"), function()
				local target = ctx.chooseActor()
				if target then
					command("invite", { target = target })
				end
			end)
		end
		if Clan.allowed(state, ctx.actorId, "territory") then
			add(ctx.text("clan.relocate"), function()
				local territory = ctx.chooseTerritory()
				if territory then
					command("relocate", { territory = territory })
				end
			end)
		end
		for _, operation in { "deposit", "withdraw" } do
			if Clan.allowed(state, ctx.actorId, operation) then
				add(ctx.text("clan." .. operation), function()
					local amount = ctx.chooseAmount()
					if amount then
						ctx.clanWallet(state.clanId, operation, amount)
					end
				end)
			end
		end
		for _, row in view.research do
			add(
				ctx.text(row.id) .. " / " .. row.cost,
				if row.canStart
					then function()
						command("research-start", { id = row.id })
					end
					else nil
			)
		end
		for jobId, job in state.jobs do
			if job.status == "pending" then
				add(ctx.text(job.definition) .. " / " .. math.max(0, job.finishAt - ctx.serverNow()))
				if Clan.allowed(state, ctx.actorId, "research") then
					add(ctx.text("clan.research-complete"), function()
						command("research-complete", { jobId = jobId })
					end)
					add(ctx.text("clan.research-cancel"), function()
						command("research-cancel", { jobId = jobId })
					end)
				end
			end
		end
		add(ctx.text(if view.govern then "clan.dissolve" else "clan.leave"), function()
			local operation = if view.govern then "dissolve" else "leave"
			if ctx.confirm("clan." .. operation, state.clanId) then
				command(operation, {})
			end
		end)
	end)
end

return M
