--!strict
-- Aerial photo controls: seven buttons in a three-column grid wrap to three rows on a narrow
-- phone. A fixed 92 px frame once overlapped Capture onto Return and trapped the player in
-- the aerial view (2026-10-23 Studio). The frame must grow with its rows.
local fs = require("@lune/fs")

return {
	["aerial photo controls grow with their rows instead of a fixed height"] = function()
		local source = fs.readFile("games/robango-island/src/client/RobangoIslandClient.client.luau")
		local first =
			assert(string.find(source, 'aerialControls.Name, aerialControls.Visible = "PhotoControls"', 1, true))
		local last = assert(string.find(source, "local aerialButtons", first, true))
		local block = string.sub(source, first, last)
		assert(
			string.find(block, "aerialControls.AutomaticSize = Enum.AutomaticSize.Y", 1, true),
			"frame grows with rows"
		)
		assert(not string.find(block, "UDim2.new(1, -24, 0, 92)", 1, true), "no fixed 92 px frame")
		assert(not string.find(block, "Vector2.new(520, 92)", 1, true), "no 92 px height cap")
	end,
}
