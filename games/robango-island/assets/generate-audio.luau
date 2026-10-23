--!strict
local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local Render = require("./render-audio")
local Wav = require("../../../cli/forge/lib/wav")
local Manifest = require("../../../cli/forge/commands/genmanifest")
local root = "games/robango-island/"
local input = "assets/robango-audio.yml"
local doc = serde.decode("yaml", fs.readFile(root .. input))
local generator = fs.readFile(root .. "assets/render-audio.luau")
-- `--only k1,k2 --created YYYY-MM-DD` renders just new cues: a full run rewrites every entry as
-- NotUploaded and would drop recorded upload ids.
local only: { [string]: boolean }? = nil
local created = "2026-10-21"
for i, arg in process.args do
	if arg == "--only" then
		only = {}
		for _, key in string.split(assert(process.args[i + 1], "--only needs keys"), ",") do
			(only :: any)[key] = true
		end
	elseif arg == "--created" then
		created = assert(process.args[i + 1], "--created needs a date")
	end
end
local rows = {}
fs.writeDir(root .. "assets/audio")
for _, cue in doc.cues do
	if only and not only[cue.key] then
		continue
	end
	local sound = Render.render(cue, doc.sampleRate)
	local bytes = Wav.encode(sound)
	local key = "robango-" .. cue.key
	local path = "assets/audio/" .. key .. ".wav"
	fs.writeFile(root .. path, bytes)
	local digest = "sha256:" .. serde.hash("sha256", buffer.tostring(bytes))
	local block = table.concat({
		"  - key: " .. key,
		"    kind: " .. (if cue.kind == "music" then "bgm" else "sfx"),
		"    tool: forge-procgen",
		"    source: " .. Manifest.yamlQuote("first-party procedural Robango " .. cue.key),
		"    path: " .. path,
		"    assetId: 0",
		"    moderation: NotUploaded",
		"    provenance:",
		"      digest: " .. digest,
		"      recipe:",
		"        id: gen-audio",
		"        version: 1",
		"        input: " .. Manifest.yamlQuote(input .. "#" .. cue.key),
		"        inputVersion: sha256:" .. serde.hash("sha256", serde.encode("json", cue) .. generator),
		"      provider:",
		"        name: forge-procgen",
		"        version: 1",
		"      rights:",
		"        source: first-party generator in this repository",
		"        ownership: first-party",
		"      author: agent:omo/hephaestus",
		"      created: " .. created,
	}, "\n") .. "\n"
	Manifest.upsertAsset(root .. "assets/manifest.yml", key, block)
	table.insert(
		rows,
		{ key = key, digest = digest, bytes = buffer.len(bytes), seconds = #sound.samples / sound.sampleRate }
	)
	print(key, digest)
end
fs.writeDir(".omo/evidence/robango-recovery/p4")
fs.writeFile(".omo/evidence/robango-recovery/p4/audio-artifacts.json", serde.encode("json", rows, true))
print("audio: generated", #rows, "first-party local cues; publication not performed")
