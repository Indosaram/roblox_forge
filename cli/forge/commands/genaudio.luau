--- Locates the newest Roblox Studio install's content dir: the version-* dir
--- that contains RobloxStudioBeta.exe, chosen by most recent modification time,
--- across the per-user root (%LOCALAPPDATA%/Roblox/Versions) and the machine-wide
--- root (%ProgramFiles%/Roblox/Versions) that Studio's auto-updater may switch to.
--- Returns (contentDir, reason).
--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local assetsCommand = require("./assets")
local cliutil = require("../lib/cliutil")
local audiocues = require("../lib/audiocues")
local wav = require("../lib/wav")
local manifest = require("./genmanifest")
local M = {}
local DEFAULT_PACK = "kaiju-egg-raiders"
local function studioContentDir(): (string?, string?)
	local roots: { string } = {}
	for _, var in { "LOCALAPPDATA", "ProgramFiles" } do
		local base = process.env[var]
		if base ~= nil and base ~= "" then
			table.insert(roots, base .. "/Roblox/Versions")
		end
	end
	if #roots == 0 then
		return nil, "LOCALAPPDATA and ProgramFiles are not set; cannot locate Roblox Studio"
	end
	local best: string? = nil
	local bestStamp = -1
	for _, versionsDir in roots do
		if fs.isDir(versionsDir) then
			for _, name in fs.readDir(versionsDir) do
				local dir = versionsDir .. "/" .. name
				if string.match(name, "^version%-.+") ~= nil and fs.isFile(dir .. "/RobloxStudioBeta.exe") then
					local metadata = fs.metadata(dir)
					local stamp = if metadata.exists and metadata.modifiedAt ~= nil
						then metadata.modifiedAt.unixTimestamp
						else 0
					if stamp > bestStamp then
						bestStamp = stamp
						best = dir
					end
				end
			end
		end
	end
	if best == nil then
		return nil, "no version-* Studio install with RobloxStudioBeta.exe under " .. table.concat(roots, " or ")
	end
	return best .. "/content", nil
end

--- `forge gen audio --pack <slug> [--install]`: reads
--- games/<pack>/assets/audio.yml, synthesises every cue with the pure
--- core/domain/procgen DSP/composer, writes games/<pack>/assets/audio/<cue>.wav,
--- and upserts each cue as forge-procgen/Approved. No API keys, no network.
--- With --install it also copies the wavs into the newest Studio install's
--- content/forge/<pack>/ so rbxasset://forge/<pack>/<cue>.wav resolves.
function M.run(args: { string }, context: cliutil.CommandContext?): boolean
	local pack = DEFAULT_PACK
	local install = false
	local stamp: { author: string?, created: string? } = {}
	local index = 3
	while index <= #args do
		local flag = args[index]
		if flag == "--pack" then
			local value = args[index + 1]
			if value == nil or value == "" then
				stdio.ewrite("Error: --pack requires a value\n")
				return false
			end
			pack = value
			index += 2
		elseif flag == "--install" then
			install = true
			index += 1
		elseif flag == "--author" or flag == "--created" then
			local stampErr = manifest.parseStamp(flag, args[index + 1], stamp)
			if stampErr ~= nil then
				stdio.ewrite(stampErr)
				return false
			end
			index += 2
		else
			stdio.ewrite("Error: unknown argument '" .. tostring(flag) .. "' for forge gen audio\n")
			return false
		end
	end

	local packDir = (if context and context.packsDir then context.packsDir else "games") .. "/" .. pack
	if not fs.isDir(packDir) then
		stdio.ewrite("Error: unknown game pack '" .. pack .. "' (missing " .. packDir .. "/)\n")
		return false
	end

	local audioPath = packDir .. "/assets/audio.yml"
	if not fs.isFile(audioPath) then
		stdio.ewrite("Error: missing " .. audioPath .. "\n")
		return false
	end
	local decodeOk, doc = pcall(function()
		return serde.decode("yaml", fs.readFile(audioPath))
	end)
	if not decodeOk or typeof(doc) ~= "table" then
		stdio.ewrite("Error: failed to decode " .. audioPath .. "\n")
		return false
	end
	local stampLines, stampErr = manifest.stampLines(stamp)
	if stampErr ~= nil then
		stdio.ewrite(stampErr)
		return false
	end
	local cues, errors = audiocues.plan(doc)
	if cues == nil or #errors > 0 then
		for _, err in errors do
			stdio.ewrite("Error: " .. err .. "\n")
		end
		return false
	end
	local planned = cues :: { audiocues.Cue }

	manifest.ensureDir(packDir .. "/assets")
	manifest.ensureDir(packDir .. "/assets/audio")

	local manifestPath = packDir .. "/assets/manifest.yml"
	local written: { { key: string, relPath: string } } = {}
	for _, cue in planned do
		local sound = audiocues.render(cue)
		local bytes = wav.encode(sound)
		local relPath = "assets/audio/" .. cue.key .. ".wav"
		fs.writeFile(packDir .. "/" .. relPath, bytes)
		local seconds = #sound.samples / sound.sampleRate
		stdio.write(
			string.format(
				"%s %s %.2fs %d bytes sha256=%s\n",
				cue.key,
				relPath,
				seconds,
				buffer.len(bytes),
				serde.hash("sha256", buffer.tostring(bytes))
			)
		)
		local block = table.concat({
			"  - key: " .. cue.key,
			"    kind: " .. (if cue.kind == "music" then "bgm" else "sfx"),
			"    tool: forge-procgen",
			"    source: " .. manifest.yamlQuote("procedural audio/" .. cue.key),
			"    path: " .. relPath,
			"    assetId: 0",
			"    moderation: Approved",
			-- Provenance of the bytes just written: the cue spec is the recipe
			-- input, the synthesiser is the provider. This records that the WAV
			-- is lawful and reproducible, never that it sounds good.
			"    provenance:",
			"      digest: sha256:" .. serde.hash("sha256", buffer.tostring(bytes)),
			"      recipe:",
			"        id: gen-audio",
			"        version: " .. audiocues.RECIPE_VERSION,
			"        input: " .. manifest.yamlQuote("assets/audio.yml#" .. cue.key),
			"        inputVersion: sha256:" .. serde.hash("sha256", serde.encode("json", cue)),
			"      provider:",
			"        name: forge-procgen",
			"        version: " .. audiocues.RECIPE_VERSION,
			"      rights:",
			"        source: " .. manifest.yamlQuote("first-party generator in this repository"),
			"        ownership: first-party",
			table.unpack(stampLines),
		}, "\n") .. "\n"
		manifest.upsertAsset(manifestPath, cue.key, block)
		table.insert(written, { key = cue.key, relPath = relPath })
	end

	-- Refresh src/shared/Assets.luau from the manifest we just upserted, via the
	-- same path as `forge assets codegen`, so `forge check` does not see drift.
	if not assetsCommand.run({ "assets", "codegen", "--pack", pack }, context) then
		return false
	end

	if install then
		local contentDir, reason = studioContentDir()
		if contentDir == nil then
			stdio.ewrite("Error: " .. tostring(reason) .. "\n")
			return false
		end
		local target = contentDir .. "/forge/" .. pack
		manifest.ensureDir(contentDir .. "/forge")
		manifest.ensureDir(target)
		for _, entry in written do
			fs.copy(packDir .. "/" .. entry.relPath, target .. "/" .. entry.key .. ".wav", true)
		end
		stdio.write(string.format("gen audio: installed %d wavs to %s\n", #written, target))
	end

	stdio.write(string.format("gen audio: wrote %d cues for %s\n", #written, pack))
	return true
end
return M
