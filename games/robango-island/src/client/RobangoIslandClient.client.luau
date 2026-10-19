--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = ReplicatedStorage:WaitForChild("Forge")
local Shared = Forge.games["robango-island"].src.shared

local SurvivalAudio = require(Forge.genres["survival-coop"].module.SurvivalAudio)
local audio = SurvivalAudio.start(require(Shared.AudioConfig))
script.Destroying:Connect(audio.destroy)

local Client = require(Forge.core.infra.genre.Client)
local gui = Client.start({ controls = require(Shared.GenreUI) })
gui.Destroying:Connect(audio.destroy)

-- The pack ships en-us and ko-kr; every survival-coop view picks Korean from a "ko" prefix.
local locale = game:GetService("Players").LocalPlayer.LocaleId
local names = require(Shared.EntityNames)(locale)

local GatheringClient = require(Forge.genres["survival-coop"].module.GatheringClient)
local gathering = GatheringClient.start({ locale = locale, names = names })
gui.Destroying:Connect(gathering.destroy)

local SurvivalHUD = require(Forge.genres["survival-coop"].module.SurvivalHUD)
local content = require(Shared.SurvivalContent)
local worldConfig = require(Shared.SurvivalWorldConfig)
local origin = worldConfig.tribe.origin
gui.Enabled = false
local hud = SurvivalHUD.start({
	content = content,
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		grid = require(Forge.core["ui-kit"].InventoryGrid),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	settlementOrigin = Vector3.new(origin.x, origin.y, origin.z),
	locale = locale,
	names = names,
})
gui.Destroying:Connect(hud.destroy)
script.Destroying:Connect(hud.destroy)

local ExtensionPanels = require(Forge.genres["survival-coop"].module.ExtensionPanels)
local panels = ExtensionPanels.start({
	ui = {
		components = require(Forge.core["ui-kit"].Components),
		theme = require(Forge.core["ui-kit"].Theme),
	},
	locale = locale,
	names = names,
	-- One sheet at a time: a panel opening closes the HUD sheet, and the reverse below.
	onOpen = hud.close,
})
hud.opened:Connect(function()
	if hud.isOpen() then
		panels.closeAll()
	end
end)
gui.Destroying:Connect(panels.destroy)
script.Destroying:Connect(panels.destroy)

local QuarterView = require(Forge.core.infra.camera.QuarterView)
local camera = QuarterView.start()
gui.Destroying:Connect(camera.stop)
script.Destroying:Connect(camera.stop)
