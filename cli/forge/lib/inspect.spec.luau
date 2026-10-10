--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local inspect = require("./inspect")
return {
	["project assertions retain class and require checks"] = function()
		local root = (process.env.TEMP or "C:/Windows/Temp")
			.. "/forge-inspect-"
			.. serde.hash("sha256", tostring(os.clock()))
		fs.writeDir(root)
		local ok, reason = xpcall(function()
			fs.writeFile(root .. "/Entry.server.luau", 'require("./Shared")\n')
			fs.writeFile(root .. "/Shared.luau", "return {}\n")
			fs.writeFile(
				root .. "/default.project.json",
				serde.encode("json", {
					name = "inspect-fixture",
					tree = {
						["$className"] = "DataModel",
						ServerScriptService = {
							Entry = { ["$path"] = "Entry.server.luau" },
							Shared = { ["$path"] = "Shared.luau" },
						},
					},
				})
			)
			local place = root .. "/place.rbxl"
			local built = process.exec("rojo", { "build", root .. "/default.project.json", "-o", place })
			assert(built.ok, built.stderr)
			local expected = { { path = "ServerScriptService.Entry", expected = "Script" } }
			local result = inspect.inspectPlaceFile(place, expected)
			assert(result.ok and result.resolvedRequiresCount == 1, table.concat(result.errors, "; "))
			assert(not inspect.inspectPlaceFile(place).ok, "legacy required structure was weakened")
			expected[1].expected = "ModuleScript"
			assert(not inspect.inspectPlaceFile(place, expected).ok, "wrong class accepted")
			expected[1] = { path = "ServerScriptService.Absent", expected = "Script" }
			assert(not inspect.inspectPlaceFile(place, expected).ok, "missing entry accepted")
			fs.writeFile(root .. "/Shared.luau", 'return require("./Absent")\n')
			built = process.exec("rojo", { "build", root .. "/default.project.json", "-o", place })
			assert(built.ok, built.stderr)
			expected[1] = { path = "ServerScriptService.Entry", expected = "Script" }
			assert(not inspect.inspectPlaceFile(place, expected).ok, "unresolved require accepted")
		end, debug.traceback)
		fs.removeDir(root)
		assert(ok, tostring(reason))
	end,
}
