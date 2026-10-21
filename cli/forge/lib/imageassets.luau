--!strict
-- Image publication checkpoints each irreversible create before polling. The
-- manifest assetId is always image content, never the enclosing Decal id.
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local audioassets = require("./audioassets")

local M = {}
local BASE = "https://apis.roblox.com/assets/v1/"

export type Dependencies = {
	request: (any) -> any,
	wait: (number) -> (),
	checkpoint: (any) -> (),
}

local function moderation(state: any): string?
	local states = {
		Approved = "Approved",
		Reviewing = "PendingModeration",
		PendingModeration = "PendingModeration",
		Rejected = "Rejected",
		MODERATION_STATE_APPROVED = "Approved",
		MODERATION_STATE_REVIEWING = "PendingModeration",
		MODERATION_STATE_REJECTED = "Rejected",
	}
	return states[state]
end

function M.multipart(boundary: string, request: any, filename: string, bytes: string): string
	return table.concat({
		"--" .. boundary .. "\r\n",
		'Content-Disposition: form-data; name="request"\r\nContent-Type: application/json\r\n\r\n',
		serde.encode("json", request) .. "\r\n",
		"--" .. boundary .. "\r\n",
		'Content-Disposition: form-data; name="fileContent"; filename="' .. filename .. '"\r\n',
		"Content-Type: image/png\r\n\r\n" .. bytes .. "\r\n",
		"--" .. boundary .. "--\r\n",
	})
end

-- Decode the actual Decal container; neither subtracting one from its id nor
-- substituting a thumbnail URL produces the image content id.
function M.imageId(bytes: string): number
	-- Asset delivery normally serves the Decal as XML. Read the explicit
	-- Texture content before reflection migrations can discard legacy fields.
	local texture = string.match(bytes, '<Content name="Texture">%s*<url>(.-)</url>')
		or string.match(bytes, '<Content name="ColorMapContent">%s*<url>(.-)</url>')
	if texture ~= nil then
		local direct = tonumber(string.match(texture, "^rbxassetid://(%d+)$") or string.match(texture, "[?&]id=(%d+)"))
		assert(direct ~= nil and direct > 0, "Decal Texture has no image content id")
		return direct
	end
	local instances = roblox.deserializeModel(bytes)
	local id: number? = nil
	for _, instance in instances do
		local candidates = { instance }
		for _, child in instance:GetDescendants() do
			table.insert(candidates, child)
		end
		for _, candidate in candidates do
			if candidate:IsA("Decal") then
				-- Round-trip to canonical XML rather than reading Texture directly:
				-- current reflection migrates that property to ColorMapContent.
				local xml = roblox.serializeModel({ candidate }, true)
				local canonicalTexture = string.match(xml, '<Content name="Texture">%s*<url>(.-)</url>')
					or string.match(xml, '<Content name="ColorMapContent">%s*<url>(.-)</url>')
					or ""
				id = tonumber(
					string.match(canonicalTexture, "^rbxassetid://(%d+)$")
						or string.match(canonicalTexture, "[?&]id=(%d+)")
				)
			end
		end
		instance:Destroy()
	end
	assert(id ~= nil and id > 0 and id % 1 == 0, "delivered Decal has no image content id")
	return id :: number
end

-- Only explicit 429s are retried for POST: a transport error might have
-- created an asset already and is not safe to repeat automatically.
local function request(deps: Dependencies, params: any): any
	for attempt = 1, 6 do
		local response = deps.request(params)
		if response.statusCode ~= 429 then
			assert(response.ok, string.format("HTTP %d: %s", response.statusCode, response.body))
			return response
		end
		assert(attempt < 6, "HTTP 429: bounded retry budget exhausted; rerun to resume")
		local retryAfter = tonumber((response.headers or {})["retry-after"])
		deps.wait(math.min(60, math.max(2 ^ (attempt - 1), retryAfter or 0)))
	end
	error("unreachable")
end

function M.publish(options: any, deps: Dependencies): any
	local cached = options.cached
	local entry: any = if cached ~= nil and cached.creator == options.creator
		then table.clone(cached)
		else {
			creator = options.creator,
			sha256 = options.sha256,
		}
	if options.dryRun then
		return entry
	end
	local headers = { ["x-api-key"] = options.apiKey }
	if entry.operationId == nil and entry.decalAssetId == nil then
		local boundary = "----forgeimage" .. options.sha256
		local create = request(deps, {
			url = BASE .. "assets",
			method = "POST",
			headers = {
				["x-api-key"] = options.apiKey,
				["content-type"] = "multipart/form-data; boundary=" .. boundary,
			},
			body = M.multipart(boundary, {
				assetType = "Decal",
				displayName = options.key,
				description = "Forge icon " .. options.key,
				creationContext = { creator = options.creatorFields },
			}, options.key .. ".png", options.bytes),
		})
		local operationId, err = audioassets.parseCreateResponse(create.body)
		assert(operationId ~= nil, err)
		entry.operationId = operationId
		deps.checkpoint(entry)
	end
	if entry.decalAssetId == nil then
		for attempt = 1, 60 do
			local poll = serde.decode(
				"json",
				request(deps, {
					url = BASE .. "operations/" .. entry.operationId,
					method = "GET",
					headers = headers,
				}).body
			)
			if poll.error ~= nil then
				error("operation failed: " .. serde.encode("json", poll.error))
			end
			if poll.done == true then
				local asset = poll.response
				local id = tonumber(asset and asset.assetId)
				assert(id ~= nil and id > 0 and id % 1 == 0, "operation has no positive assetId")
				entry.decalAssetId = id
				entry.assetType = asset.assetType
				entry.moderation = moderation(asset.moderationResult and asset.moderationResult.moderationState)
				deps.checkpoint(entry)
				break
			end
			assert(attempt < 60, "operation still pending; rerun to resume")
			deps.wait(1)
		end
	end
	if entry.moderation ~= "Approved" and entry.moderation ~= "Rejected" then
		local asset = serde.decode(
			"json",
			request(deps, {
				url = BASE .. "assets/" .. tostring(entry.decalAssetId),
				method = "GET",
				headers = headers,
			}).body
		)
		entry.moderation = moderation(asset.moderationResult and asset.moderationResult.moderationState)
		assert(entry.moderation ~= nil, "missing or unknown moderation state")
		deps.checkpoint(entry)
	end
	if entry.moderation == "Approved" and entry.assetId == nil then
		if entry.assetType == "Image" or entry.assetType == "ASSET_TYPE_IMAGE" then
			entry.assetId = entry.decalAssetId
		else
			local delivery = serde.decode(
				"json",
				request(deps, {
					url = "https://apis.roblox.com/asset-delivery-api/v1/assetId/" .. tostring(entry.decalAssetId),
					method = "GET",
					headers = { ["x-api-key"] = options.apiKey, ["Roblox-AssetFormat"] = "xml" },
				}).body
			)
			assert(
				type(delivery.location) == "string" and string.match(delivery.location, "^https://"),
				"missing delivery location"
			)
			-- Signed CDN URL, deliberately no Open Cloud secret in this request.
			entry.assetId = M.imageId(request(deps, { url = delivery.location, method = "GET" }).body)
		end
		deps.checkpoint(entry)
	end
	return entry
end

return M
