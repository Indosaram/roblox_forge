--!strict
-- Specs for GenProviders: licensed routing, request payloads, the dry-run
-- preview, missing-env refusal, and the injected (network-free) request path.

local licenses = require("./licenses")

local GenProviders = require("./genproviders")

local function contains(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

return {
	["every kind routes to a provider on the license allow-list"] = function()
		for _, kind in GenProviders.kinds do
			local route, err = GenProviders.route(kind)
			assert(route ~= nil, "kind '" .. kind .. "' must route: " .. tostring(err))
			local typed = route :: GenProviders.Route
			local allowed = licenses.resolve(typed.provider)
			assert(allowed, "provider '" .. typed.provider .. "' must be allowed")
			assert(licenses.denied[typed.provider] == nil, "provider '" .. typed.provider .. "' must not be denied")
		end
	end,

	["routing never selects a denied tool"] = function()
		for _, denied in { "audiocraft", "roblox-cube", "hunyuan3d-2" } do
			for _, kind in GenProviders.kinds do
				local route = GenProviders.route(kind) :: GenProviders.Route
				assert(route.provider ~= denied, kind .. " must not route to denied tool " .. denied)
			end
		end
	end,

	["unknown kind is refused with the valid kinds"] = function()
		local route, err = GenProviders.route("video")
		assert(route == nil, "unknown kind must not route")
		assert(contains(err :: string, "unknown asset kind"), "reason: " .. tostring(err))
		assert(contains(err :: string, "mesh"), "reason must list valid kinds: " .. tostring(err))
	end,

	["mesh builds a GLB request to the TRELLIS_URL endpoint"] = function()
		local request =
			GenProviders.buildRequest("mesh", "a rock", { TRELLIS_URL = "http://trellis.local/generate" }) :: GenProviders.Request
		assert(request.provider == "trellis", "provider: " .. request.provider)
		assert(request.method == "POST", "method: " .. request.method)
		assert(request.url == "http://trellis.local/generate", "url: " .. request.url)
		assert(request.ext == "glb", "ext: " .. request.ext)
		assert(not request.envMissing, "env should be present")
		assert(contains(request.body, "a rock"), "body carries the prompt: " .. request.body)
	end,

	["sfx builds a text request to the elevenlabs sound-generation endpoint"] = function()
		local request =
			GenProviders.buildRequest("sfx", "coin ding", { ELEVENLABS_API_KEY = "secret-key" }) :: GenProviders.Request
		assert(request.provider == "elevenlabs", "provider: " .. request.provider)
		assert(request.url == "https://api.elevenlabs.io/v1/sound-generation", "url: " .. request.url)
		assert(request.ext == "mp3", "ext: " .. request.ext)
		assert(request.headers["xi-api-key"] == "secret-key", "api key header is set")
		assert(contains(request.body, "coin ding"), "body carries the text: " .. request.body)
		assert(contains(request.body, "text"), "body uses the text field: " .. request.body)
	end,

	["image builds a PNG request to the IMAGE_GEN_URL endpoint"] = function()
		local request =
			GenProviders.buildRequest("image", "egg icon", { IMAGE_GEN_URL = "http://img.local/png" }) :: GenProviders.Request
		assert(request.provider == "studio-mcp", "provider: " .. request.provider)
		assert(request.url == "http://img.local/png", "url: " .. request.url)
		assert(request.ext == "png", "ext: " .. request.ext)
		assert(contains(request.body, "egg icon"), "body carries the prompt: " .. request.body)
	end,

	["dry-run preview contains provider, url, and target path"] = function()
		local request =
			GenProviders.buildRequest("mesh", "a rock", { TRELLIS_URL = "http://trellis.local/generate" }) :: GenProviders.Request
		local target = GenProviders.targetPath("kaiju-egg-raiders", "mesh", "rockA", request.ext)
		assert(target == "games/kaiju-egg-raiders/assets/mesh/rockA.glb", "target: " .. target)
		local preview = GenProviders.renderPreview(request, target)
		assert(contains(preview, "trellis"), "preview names the provider: " .. preview)
		assert(contains(preview, "http://trellis.local/generate"), "preview shows the url: " .. preview)
		assert(
			contains(preview, "games/kaiju-egg-raiders/assets/mesh/rockA.glb"),
			"preview shows the target: " .. preview
		)
	end,

	["preview masks the api key header"] = function()
		local request =
			GenProviders.buildRequest("sfx", "boom", { ELEVENLABS_API_KEY = "secret-key" }) :: GenProviders.Request
		local preview = GenProviders.renderPreview(request, "games/p/assets/sfx/boom.mp3")
		assert(not contains(preview, "secret-key"), "secret must not be printed: " .. preview)
		assert(contains(preview, "***"), "masked header is shown: " .. preview)
	end,

	["a missing env var yields the missing env message"] = function()
		local mesh = GenProviders.buildRequest("mesh", "a rock", {}) :: GenProviders.Request
		assert(mesh.envMissing, "mesh env should be reported missing")
		assert(GenProviders.missingEnv(mesh) == "missing env TRELLIS_URL", "mesh message")

		local sfx = GenProviders.buildRequest("sfx", "boom", {}) :: GenProviders.Request
		assert(GenProviders.missingEnv(sfx) == "missing env ELEVENLABS_API_KEY", "sfx message")

		local image = GenProviders.buildRequest("image", "icon", {}) :: GenProviders.Request
		assert(GenProviders.missingEnv(image) == "missing env IMAGE_GEN_URL", "image message")
	end,

	["a present env var has no missing env message"] = function()
		local request =
			GenProviders.buildRequest("image", "icon", { IMAGE_GEN_URL = "http://img.local" }) :: GenProviders.Request
		assert(GenProviders.missingEnv(request) == nil, "no missing env message when set")
	end,

	["send uses the injected request function and returns the body"] = function()
		local request =
			GenProviders.buildRequest("mesh", "a rock", { TRELLIS_URL = "http://trellis.local/generate" }) :: GenProviders.Request
		local captured: any = nil
		local fake = function(options: any): any
			captured = options
			return { ok = true, statusCode = 200, body = "GLBDATA" }
		end
		local body, err = GenProviders.send(request, fake)
		assert(err == nil, "unexpected error: " .. tostring(err))
		assert(body == "GLBDATA", "body is returned: " .. tostring(body))
		assert(captured.url == "http://trellis.local/generate", "fake saw the url")
		assert(captured.method == "POST", "fake saw the method")
		assert(contains(captured.body, "a rock"), "fake saw the body")
	end,

	["a non-2xx response is reported as a failure"] = function()
		local request =
			GenProviders.buildRequest("image", "icon", { IMAGE_GEN_URL = "http://img.local" }) :: GenProviders.Request
		local fake = function(): any
			return { ok = false, statusCode = 500, body = "" }
		end
		local body, err = GenProviders.send(request, fake)
		assert(body == nil, "failure returns no body")
		assert(contains(err :: string, "HTTP 500"), "reason: " .. tostring(err))
	end,

	["F5: a requestFn that throws (net.request on a transport error) is reported, not propagated"] = function()
		local request =
			GenProviders.buildRequest("mesh", "a rock", { TRELLIS_URL = "http://127.0.0.1:1" }) :: GenProviders.Request
		local throwing = function(): any
			error("connection refused (os error 10061)")
		end
		local ok, body, err = pcall(GenProviders.send, request, throwing)
		assert(ok, "GenProviders.send must not itself throw: " .. tostring(body))
		assert(body == nil, "a thrown transport error returns no body")
		assert(
			contains(err :: string, "provider request failed"),
			"reason should name a provider request failure: " .. tostring(err)
		)
	end,

	["the manifest block records the provider and NotUploaded"] = function()
		local block = GenProviders.manifestBlock("rockA", "mesh", "trellis", "a rock", "assets/mesh/rockA.glb")
		assert(contains(block, "key: rockA"), "key: " .. block)
		assert(contains(block, "tool: trellis"), "tool: " .. block)
		assert(contains(block, "path: assets/mesh/rockA.glb"), "path: " .. block)
		assert(contains(block, "moderation: NotUploaded"), "moderation: " .. block)
	end,
}
