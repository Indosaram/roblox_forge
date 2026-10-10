--!strict
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local identity = require("./buildidentity")
local driver = require("./qastudio")
local qascenario = require("./qascenario")
local Png = require("./png")
local Pixels = require("../../../core/domain/procgen/Pixels")

return {
	["owned bootstrap ignores configured claims and retains negative discovery"] = function()
		local path = ".omo/qastudio-bootstrap-negative.json"
		assert(not fs.isFile(path), "owned fixture already exists")
		fs.writeFile(
			path,
			serde.encode("json", {
				capabilities = { studio_connected = { available = true, invocation = "configured-not-observed" } },
			})
		)
		local ok, reason = pcall(function()
			local blocked = driver.run("invalid-scenario", path, true)
			assert(not blocked.ok and blocked.discovery.status == "BLOCKED", "negative discovery required")
			for _, name in driver.REQUIRED_CAPABILITIES do
				assert(blocked.discovery.capabilities[name].available == false, "config cannot prove capability")
			end
			assert(not driver.readiness(path).ok, "normal admission remains strict")
		end)
		fs.removeFile(path)
		assert(ok, tostring(reason))
	end,
	["original baseline JPEG is decoded and truncated entropy is refused"] = function()
		local function segment(marker: number, data: string): string
			return string.char(255, marker, math.floor((#data + 2) / 256), (#data + 2) % 256) .. data
		end
		local bytes = string.char(255, 216)
			.. segment(219, string.char(0) .. string.rep(string.char(1), 64))
			.. segment(192, string.char(8, 0, 8, 0, 8, 1, 1, 17, 0))
			.. segment(
				196,
				string.char(0, 1)
					.. string.rep(string.char(0), 16)
					.. string.char(16, 1)
					.. string.rep(string.char(0), 16)
			)
			.. segment(218, string.char(1, 1, 0, 0, 63, 0))
			.. string.char(63, 255, 217)
		local raster = driver.imageRaster(bytes)
		assert(
			raster.format == "jpeg" and raster.width == 8 and raster.height == 8,
			'raster.format == "jpeg" and raster.width == 8 and raster.height == 8'
		)
		assert(
			not pcall(driver.imageRaster, string.sub(bytes, 1, #bytes - 3) .. string.char(255, 217)),
			"not pcall(driver.imageRaster, string.sub(bytes, 1, #bytes - 3) .. string.char(255, 217))"
		)
	end,
	["capture geometry separates device fractional logical units and original raster"] = function()
		local cases: { { any } } = { { "desktop", 1280, 720, 1600, 900 }, { "mobile", 390, 844, 488, 1055 } }
		for _, dimensions in cases do
			local surface, width, height, rw, rh = table.unpack(dimensions)
			local bytes = buffer.tostring(Png.encode(Pixels.new(rw, rh)))
			local lw = if surface == "mobile" then 390.3999938964844 else 1280
			local lh = if surface == "mobile" then 844 else 720
			local top = if surface == "mobile" then 44 else 0
			local sh = if surface == "mobile" then 763 else 720
			local capture: any = {
				schemaVersion = 2,
				device = {
					id = "fixture",
					surface = surface,
					width = width,
					height = height,
					scaling = "ActualResolution",
					form = if surface == "mobile" then "Phone" else "Desktop",
					orientation = if surface == "mobile" then "Portrait" else "LandscapeLeft",
				},
				logical = {
					full = { x = 0, y = 0, width = lw, height = lh },
					viewport = { x = 0, y = top, width = lw, height = sh },
					safeArea = { x = 0, y = top, width = lw, height = sh },
					insets = { left = 0, top = top, right = 0, bottom = lh - top - sh },
				},
				raster = { format = "png", width = rw, height = rh },
				logicalToRaster = {
					origin = "full-screen",
					scaleX = rw / lw,
					scaleY = rh / lh,
					offsetX = 0,
					offsetY = 0,
				},
				criticalUI = { { id = "action", x = 10, y = 50, width = 100, height = 40 } },
			}
			assert(driver.validateCapture(capture, bytes, surface), "original unequal raster is admissible")
			for _, bad in { 0, -1, math.huge, 0 / 0 } do
				capture.logical.viewport.width = bad
				assert(
					not driver.validateCapture(capture, bytes, surface),
					"not driver.validateCapture(capture, bytes, surface)"
				)
			end
			capture.logical.viewport.width = lw
			capture.device.width += 1
			assert(
				not driver.validateCapture(capture, bytes, surface),
				"device dimension drift must reject the capture"
			)
			capture.device.width = width
			capture.raster.width += 1
			assert(
				not driver.validateCapture(capture, bytes, surface),
				"raster dimension drift must reject the capture"
			)
			capture.raster.width = rw
			capture.logicalToRaster.scaleX = 1
			assert(
				not driver.validateCapture(capture, bytes, surface),
				"logical to raster scale drift must reject the capture"
			)
			capture.logicalToRaster.scaleX = rw / lw
			capture.criticalUI[1].x = lw
			assert(not driver.validateCapture(capture, bytes, surface), "critical UI drift must reject the capture")
			capture.criticalUI[1].x = 10
			capture.criticalUI[2] = { id = "overlap", x = 15, y = 50, width = 20, height = 20 }
			assert(
				not driver.validateCapture(capture, bytes, surface),
				"overlapping critical UI must reject the capture"
			)
			capture.criticalUI[2] = nil
			capture.schemaVersion = 1
			assert(not driver.validateCapture(capture, bytes, surface), "stale capture schema version must reject")
			capture.schemaVersion = 2
			assert(
				not driver.validateCapture(capture, string.sub(bytes, 1, #bytes - 1), surface),
				"not driver.validateCapture(capture, string.sub(bytes, 1, #bytes - 1), surface)"
			)
			assert(
				not driver.validateCapture(capture, string.sub(bytes, 1, 50) .. "x" .. string.sub(bytes, 52), surface),
				'not driver.validateCapture(capture, string.sub(bytes, 1, 50) .. "x" .. string.sub(bytes, 52), surface)'
			)
			assert(
				not driver.validateCapture(capture, bytes .. "trailing", surface),
				'not driver.validateCapture(capture, bytes .. "trailing", surface)'
			)
			assert(
				not driver.validateCapture(capture, "not a PNG", surface),
				'not driver.validateCapture(capture, "not a PNG", surface)'
			)
		end
	end,
	["discovery availability never substitutes for a parsed owned Studio run"] = function()
		local path = ".omo/qastudio-spec-discovery.json"
		local root = ".omo/fixtures/qastudio-owned"
		assert(not fs.isDir(root), "owned fixture already exists")
		local capabilities = {}
		for _, name in driver.REQUIRED_CAPABILITIES do
			capabilities[name] = { available = true, invocation = "list_roblox_studios({})" }
		end
		fs.writeFile(path, serde.encode("json", { capabilities = capabilities }))
		local ok, err = pcall(function()
			assert(driver.readiness(path).ok, "discovery fixture is ready")
			assert(not driver.run("name-only", path).ok, "name alone cannot drive a scenario")
			local steps: { qascenario.Step } = {
				{ op = "expect_members", members = { "first", "second" } },
				{ op = "capture", target = "viewport" },
			}
			local scenario = {
				name = "owned-studio",
				genre = "survival-coop",
				pack = "primal-isles",
				kind = "studio",
				contract_api = 1,
				timeout_seconds = 10,
				players = { "first", "second" },
				steps = steps,
			}
			local outcome = driver.run(scenario, path)
			assert(not outcome.ok and #outcome.blockers > 0, "discovery does not prove execution")
			fs.writeDir(root)
			fs.writeFile(root .. "/game.yml", "name: owned-fixture\n")
			fs.writeFile(root .. "/Main.server.luau", "return nil\n")
			fs.writeFile(
				root .. "/default.project.json",
				serde.encode("json", {
					name = "owned-fixture",
					tree = {
						["$className"] = "DataModel",
						ServerScriptService = {
							Main = { ["$path"] = "Main.server.luau" },
						},
					},
				})
			)
			local buildPath = root .. "/place.rbxl"
			local expected = identity.snapshot(root .. "/default.project.json", root, buildPath)
			local server, client = identity.runtime(expected)
			local place = roblox.Instance.new("DataModel")
			local service = roblox.Instance.new("ServerScriptService")
			service.Parent = place
			local starter = roblox.Instance.new("StarterPlayer")
			starter.Parent = place
			local scripts = roblox.Instance.new("StarterPlayerScripts")
			scripts.Parent = starter
			local a, b = roblox.Instance.new("Script"), roblox.Instance.new("LocalScript")
			a.Name, a.Source, a.Parent = "ForgeBuildIdentity", server, service
			b.Name, b.Source, b.Parent = "ForgeBuildIdentity", client, scripts
			local storage = roblox.Instance.new("ReplicatedStorage")
			storage.Parent = place
			local token = "owned-qastudio-fixture-123"
			storage:SetAttribute("ForgeQAOwner", token)
			local bytes = roblox.serializePlace(place)
			fs.writeFile(buildPath, bytes)
			fs.writeFile(
				buildPath .. ".identity.json",
				serde.encode("json", {
					schemaVersion = 1,
					identity = expected,
					ownedQaToken = token,
					build = "sha256:" .. serde.hash("sha256", bytes),
				})
			)
			local config = { buildPath = buildPath, packDir = root, ownershipToken = token }
			local function writeReceipt()
				fs.writeFile(path, serde.encode("json", { capabilities = capabilities, driver = config }))
			end
			config.ownershipToken = "wrong-qastudio-fixture-123"
			writeReceipt()
			local rejected = driver.run(scenario, path)
			assert(
				not rejected.ok
					and string.find(table.concat(rejected.blockers, " "), "OWNED_ARTIFACT_MARKER_MISMATCH", 1, true),
				"wrong owner refuses before transport"
			)
			config.ownershipToken = token
			storage:SetAttribute("ForgeQAOwner", "wrong-qastudio-fixture-123")
			local substituted = roblox.serializePlace(place)
			fs.writeFile(buildPath, substituted)
			fs.writeFile(
				buildPath .. ".identity.json",
				serde.encode("json", {
					schemaVersion = 1,
					identity = expected,
					ownedQaToken = token,
					build = "sha256:" .. serde.hash("sha256", substituted),
				})
			)
			writeReceipt()
			local embedded = driver.run(scenario, path)
			assert(
				not embedded.ok
					and string.find(table.concat(embedded.blockers, " "), "EMBEDDED_IDENTITY_MISMATCH", 1, true),
				"fresh hash cannot hide wrong embedded owner"
			)
			fs.writeFile(buildPath, bytes)
			fs.writeFile(
				buildPath .. ".identity.json",
				serde.encode("json", {
					schemaVersion = 1,
					identity = expected,
					ownedQaToken = token,
					build = "sha256:" .. serde.hash("sha256", bytes),
				})
			)
			writeReceipt()
			local transported = driver.run(scenario, path)
			assert(not transported.ok, "missing owned IDs fail through the real local runner")
			assert(
				string.find(table.concat(transported.blockers, " "), "command", 1, true) ~= nil,
				"the runner consumes JSON stdin: " .. table.concat(transported.blockers, " ")
			)
		end)
		if fs.isDir(root) then
			fs.removeDir(root)
		end
		fs.removeFile(path)
		assert(ok, tostring(err))
	end,
}
