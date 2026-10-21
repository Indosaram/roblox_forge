--!strict
-- Host-only (luau-lsp lune set): the robango-island generated catalog is not mounted by other game packs; marker: require("@lune/task")
local Panel = require("./JournalPanel")
local Chapters = require("../../../core/domain/journal/Chapters")
local Content = require("../../../games/robango-island/src/shared/SurvivalContent")
local Catalog = assert(Content.chapters, "journal catalog required")
return {
	["journal renders every generated objective and respects server gates at phone and PC widths"] = function()
		local initial = Chapters.new()
		local rows = Panel.model(Content, initial, 19)
		assert(#rows == #Catalog and #rows == 8, "entire chapter catalog")
		assert(not rows[1].canOpen and rows[1].reason == "LEVEL_GATE", "level 19 disabled")
		initial = assert(Chapters.open(initial, Catalog, rows[1].id, 60), "open chapter")
		rows = Panel.model(Content, initial, 60)
		assert(not rows[1].canClaim and not rows[2].canOpen, "incomplete claim and future chapter disabled")
		assert(#rows[1].objectives == #Catalog[1].objectives, "no objective truncation")
		for _, width in { 360, 1280 } do
			local close: any = nil
			local sheet: any = {
				frame = { Visible = true },
				scroll = {},
				close = {
					Activated = {
						Connect = function(_self, callback)
							close = callback
							return { Disconnect = function() end }
						end,
					},
				},
			}
			local function node(): any
				local item: any = { Destroy = function() end }
				return item
			end
			local panel = Panel.factory({
				content = Content,
				text = function(key)
					return key
				end,
				createGui = function()
					return node()
				end,
				fitSheet = function(frame)
					frame.width = math.min(width - 16, 720)
				end,
				rowSize = function(lines: number)
					return { width = width - 32, height = lines * 24 }
				end,
				buttonSize = { width = width - 32, height = 48 },
				level = function()
					return 60
				end,
				send = function()
					error("disabled action sent")
				end,
				ui = {
					theme = { default = {} },
					components = {
						modalSheet = function()
							return sheet
						end,
						label = function()
							return node()
						end,
						button = function()
							local button = node()
							button.Activated = {
								Connect = function()
									return { Disconnect = function() end }
								end,
							}
							return button
						end,
					},
				},
			})
			panel.open()
			assert(sheet.frame.Visible and sheet.frame.width <= width, "sheet fits viewport")
			panel.snapshot({ survivalExtensions = { journal = initial } })
			close()
			assert(not sheet.frame.Visible, "Back closes panel")
			panel.destroy()
		end
	end,
}
