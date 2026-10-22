--!strict
local Panel = require("./ClanPanel")
local Outpost = require("./OutpostPanel")
local Clan = require("../../../core/domain/settlement/Clan")
local serde = require("@lune/serde")
return {
	["actual panel renderer fits phone and desktop sends revision-bound actions and cleans subscriptions"] = function()
		for _, viewport in { { 360, 640 }, { 1280, 720 } } do
			local widgets, sends = {}, {}
			local callback: any = nil
			local destroyed, unsubscribed, unfit = false, false, false
			local membership = false
			local frame: any = {}
			local components = {}
			function components.modalSheet(): any
				return {
					frame = frame,
					scroll = {
						GetChildren = function(): any
							return {}
						end,
					},
					close = { Activated = { Connect = function() end } },
				}
			end
			local function widget(_theme: any, props: any): any
				table.insert(widgets, props)
				return {}
			end
			components.label, components.button = widget, widget
			local ctx: any = {
				ui = { components = components, theme = { default = {} } },
				playerGui = {},
				actorId = "owner",
				content = { operations = {} },
				instance = {
					new = function(): any
						return {
							Destroy = function()
								destroyed = true
							end,
						}
					end,
				},
				udim2 = {
					new = function(...: any): any
						return { ... }
					end,
					fromOffset = function(x: number, y: number): any
						return { x = x, y = y }
					end,
				},
				vector2 = {
					new = function(x: number, y: number): any
						return { x, y }
					end,
				},
				onViewport = function(listener: any): any
					listener(viewport[1], viewport[2])
					return function()
						unfit = true
					end
				end,
				onSnapshot = function(listener: any): any
					callback = listener
					return function()
						unsubscribed = true
					end
				end,
				dock = function(entry: any)
					assert(entry.icon.key == "ui.icon.social", "social icon travels through launcher")
				end,
				icons = {
					ui = function(id: string): any
						return { key = "ui.icon." .. id }
					end,
				},
				text = function(key: string): string
					return key
				end,
				openMembership = function()
					assert(frame.Visible == false, "clan must not cover membership input")
					membership = true
				end,
				encode = function(value: any): string
					return serde.encode("json", value)
				end,
				send = function(action: string, args: any)
					table.insert(sends, { action = action, args = args })
				end,
				confirm = function(): boolean
					return true
				end,
				serverNow = function(): number
					return 10
				end,
			}
			local panel = Panel.factory(ctx)
			assert(#widgets == 3, "no-clan state is visible before snapshot")
			frame.Visible = true
			widgets[2].onClick()
			assert(membership, "create opens membership")
			frame.Visible = true
			widgets[3].onClick()
			assert(frame.Visible == false, "join also clears the clan sheet")
			local state = Clan.new("a", "owner")
			state.members.helper = { role = "member", withdraw = false }
			callback({ clan = state })
			assert(
				frame.Size.x <= viewport[1] and frame.Position.y + frame.Size.y <= viewport[2],
				"rendered frame fits"
			)
			local count = #widgets
			callback({ clan = state })
			assert(#widgets == count, "unchanged snapshot preserves pressed buttons")
			for _, props in widgets do
				assert(props.size[4] == 48, "actual widgets have 48 pixel targets")
				if props.text == "clan.officer" then
					props.onClick()
				end
			end
			assert(#sends == 1 and sends[1].action == "survival-coop:clan-role", "button reaches command transport")
			assert(
				sends[1].args[2].expectedRevision == 0 and sends[1].args[2].target == "helper",
				"revision and target bound"
			)
			panel.destroy()
			assert(destroyed and unsubscribed and unfit, "all subscriptions released")
			local fitted = false
			ctx.fitSheet = function(actual)
				assert(actual == frame, "shared coordinator receives the visible clan sheet")
				fitted = true
			end
			ctx.onViewport = function()
				error("shared sheet must not retain a competing resize owner")
			end
			panel = Panel.factory(ctx)
			assert(fitted, "clan participates in shared display order and viewport fitting")
			panel.destroy()
			widgets = {}
			panel = Outpost.factory(ctx)
			callback({ outpost = { owner = "a", expiresAt = 20, matches = {} } })
			assert(#widgets == 3, "outpost renders ownership expiry and opt-in")
			panel.destroy()
		end
	end,
}
