--!strict
-- GenProviders: pure provider routing and request planning for `forge gen`.
-- Nothing here touches the network or the filesystem: the command injects an
-- environment table and a request function, so specs cover routing, payloads,
-- and the missing-env refusal without a real network call.
--
-- Each kind maps to exactly one licensed provider (licenses.luau allow-list):
--   image -> studio-mcp  (POST {prompt} to $IMAGE_GEN_URL, PNG bytes)
--   mesh  -> trellis     (POST {prompt} to $TRELLIS_URL, GLB bytes)
--   sfx   -> elevenlabs  (POST {text} to the sound-generation API, MP3 bytes)

local serde = require("@lune/serde")

local licenses = require("./licenses")

local M = {}

export type Kind = "image" | "mesh" | "sfx"

export type Route = {
	provider: string,
	env: string,
	url: string,
	fromEnvUrl: boolean,
	ext: string,
	bodyField: string,
}

export type Request = {
	kind: Kind,
	provider: string,
	method: string,
	url: string,
	headers: { [string]: string },
	body: string,
	ext: string,
	env: string,
	envMissing: boolean,
}

export type RequestFn = (options: any) -> any

-- What a generated/imported artifact records about its own production. The
-- rights fields are defaults only: `manifestBlock` prefers the license
-- registry's record for the tool so a manifest cannot claim rights the
-- registry does not grant.
export type ManifestProvenance = {
	digest: string,
	recipeId: string,
	recipeVersion: string,
	inputVersion: string,
	providerVersion: string,
	rightsSource: string,
	ownership: string,
}

-- Version of the request-shaping recipe in this module. Bump it whenever the
-- payload this CLI sends a provider changes, so a recorded artifact names the
-- exact recipe that produced it.
M.RECIPE_VERSION = "1"

local ROUTES: { [string]: Route } = {
	image = {
		provider = "studio-mcp",
		env = "IMAGE_GEN_URL",
		url = "",
		fromEnvUrl = true,
		ext = "png",
		bodyField = "prompt",
	},
	mesh = {
		provider = "trellis",
		env = "TRELLIS_URL",
		url = "",
		fromEnvUrl = true,
		ext = "glb",
		bodyField = "prompt",
	},
	sfx = {
		provider = "elevenlabs",
		env = "ELEVENLABS_API_KEY",
		url = "https://api.elevenlabs.io/v1/sound-generation",
		fromEnvUrl = false,
		ext = "mp3",
		bodyField = "text",
	},
}

-- Kinds in help/error order.
M.kinds = { "image", "mesh", "sfx" }

local SECRET_HEADERS: { [string]: boolean } = {
	authorization = true,
	["x-api-key"] = true,
	["xi-api-key"] = true,
}

local function yamlQuote(value: string): string
	local escaped = string.gsub(value, "\\", "\\\\")
	escaped = string.gsub(escaped, '"', '\\"')
	escaped = string.gsub(escaped, "\n", "\\n")
	return '"' .. escaped .. '"'
end

--- True when `kind` is one of image|mesh|sfx.
function M.isKind(kind: string): boolean
	return ROUTES[kind] ~= nil
end

--- Resolves a kind to its provider route, refusing unknown kinds and any
--- provider that the license registry does not allow. Denied tools (audiocraft,
--- roblox-cube, hunyuan3d-2) can never be selected here.
function M.route(kind: string): (Route?, string?)
	local route: Route? = ROUTES[kind]
	if route == nil then
		return nil, "unknown asset kind '" .. kind .. "'; valid kinds: " .. table.concat(M.kinds, ", ")
	end
	local typed = route :: Route
	local allowed, licenseOrReason = licenses.resolve(typed.provider)
	if not allowed then
		return nil, "refusing provider '" .. typed.provider .. "': " .. licenseOrReason
	end
	return typed, nil
end

--- Builds the provider request for `kind`. The `env` table is injected so specs
--- never read the process environment. Returns (nil, reason) only for an unknown
--- kind or a denied provider; a missing required variable is reported through
--- `request.envMissing` and the `missingEnv` helper.
function M.buildRequest(kind: string, prompt: string, env: { [string]: string? }): (Request?, string?)
	local route, reason = M.route(kind)
	if route == nil then
		return nil, reason
	end
	local typed = route :: Route

	local value = env[typed.env]
	local missing = value == nil or value == ""
	local url = typed.url
	if typed.fromEnvUrl then
		url = if missing then "<" .. typed.env .. ">" else value :: string
	end

	local headers: { [string]: string } = { ["Content-Type"] = "application/json" }
	if typed.provider == "elevenlabs" and not missing then
		headers["xi-api-key"] = value :: string
	end

	local payload: { [string]: string } = {}
	payload[typed.bodyField] = prompt

	return {
		kind = kind :: Kind,
		provider = typed.provider,
		method = "POST",
		url = url,
		headers = headers,
		body = serde.encode("json", payload),
		ext = typed.ext,
		env = typed.env,
		envMissing = missing,
	},
		nil
end

--- The exact "missing env <NAME>" message for a request whose variable is
--- unset, or nil when it is present.
function M.missingEnv(request: Request): string?
	if not request.envMissing then
		return nil
	end
	return "missing env " .. request.env
end

--- Renders the provider target path inside a pack: games/<pack>/assets/<kind>/<key>.<ext>.
function M.targetPath(pack: string, kind: string, key: string, ext: string): string
	return "games/" .. pack .. "/assets/" .. kind .. "/" .. key .. "." .. ext
end

--- Renders the request preview printed by `--dry-run` (and before a
--- missing-env refusal). Secret header values are masked, never printed.
function M.renderPreview(request: Request, targetPath: string): string
	local lines: { string } = {
		"gen: " .. request.kind .. " via " .. request.provider,
		"  method: " .. request.method,
		"  url: " .. request.url,
	}
	local names: { string } = {}
	for name in request.headers do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local value = request.headers[name]
		if SECRET_HEADERS[string.lower(name)] then
			value = "***"
		end
		table.insert(lines, "  header: " .. name .. ": " .. value)
	end
	table.insert(lines, "  body: " .. request.body)
	table.insert(lines, "  target: " .. targetPath)
	return table.concat(lines, "\n") .. "\n"
end

--- Performs the request through the injected `requestFn` (the command passes
--- `net.request`; specs pass a fake). Returns (body, nil) on success or
--- (nil, reason) on a transport error or non-2xx response. `requestFn` is
--- pcall'd because Lune's `net.request` throws on a connection failure (for
--- example connection refused) instead of returning a response table.
function M.send(request: Request, requestFn: RequestFn): (string?, string?)
	local ok, response = pcall(requestFn, {
		url = request.url,
		method = request.method,
		headers = request.headers,
		body = request.body,
	})
	if not ok then
		return nil, "provider request failed: " .. tostring(response)
	end
	if response == nil or not response.ok then
		local code = if response ~= nil then tostring(response.statusCode) else "no response"
		return nil, "provider request failed: HTTP " .. code
	end
	return response.body, nil
end

--- Renders one manifest.yml list entry for a generated asset: moderation
--- NotUploaded (never uploaded by this command) and the provider as the tool.
--- `provenance` records how the artifact was produced so the asset gate can
--- check it is lawful and reproducible; it carries no quality verdict, because
--- generating an asset says nothing about how it looks.
function M.manifestBlock(
	key: string,
	kind: string,
	tool: string,
	prompt: string,
	path: string,
	provenance: ManifestProvenance?
): string
	local lines = {
		"  - key: " .. key,
		"    kind: " .. kind,
		"    tool: " .. tool,
		"    source: " .. yamlQuote(prompt),
		"    path: " .. path,
		"    assetId: 0",
		"    moderation: NotUploaded",
	}
	if provenance ~= nil then
		local typed = provenance :: ManifestProvenance
		local rights = licenses.rights(tool)
		local rightsSource = if rights ~= nil then rights.rightsSource else typed.rightsSource
		local ownership = if rights ~= nil then rights.ownership else typed.ownership
		for _, line in
			{
				"    provenance:",
				"      digest: " .. typed.digest,
				"      recipe:",
				"        id: " .. typed.recipeId,
				"        version: " .. typed.recipeVersion,
				"        input: " .. yamlQuote(prompt),
				"        inputVersion: " .. typed.inputVersion,
				"      provider:",
				"        name: " .. tool,
				"        version: " .. typed.providerVersion,
				"      rights:",
				"        source: " .. yamlQuote(rightsSource),
				"        ownership: " .. ownership,
			}
		do
			table.insert(lines, line)
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

return M
