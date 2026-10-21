--!strict
-- A home reservation is immutable once committed. The actor fence serializes
-- first allocation; TeleportData never supplies either the owner or access code.
local Documents = require("../data/ActorDocumentStore")
local M = {}

function M.new(backend: any, options: any, placeId: number, reserve: (number) -> (string, string)): any
	local documents = Documents.new(backend, options, "home-route-v1")
	return {
		resolve = function(actor: string): (any?, string?)
			local resumed = documents.resumeActor(actor)
			if not resumed.ok then
				return nil, resumed.reason
			end
			local document, reason = documents.snapshot(actor)
			if not document then
				return nil, reason
			end
			if document.reservation then
				local released = documents.releaseActor(actor)
				return if released.ok then document.reservation else nil, released.reason
			end
			if placeId <= 0 then
				documents.releaseActor(actor)
				return nil, "unconfigured_home_place"
			end
			local ok, accessCode, privateServerId = pcall(reserve, placeId)
			if not ok then
				documents.releaseActor(actor)
				return nil, "home_reservation_failed"
			end
			local reservation =
				{ owner = actor, placeId = placeId, accessCode = accessCode, privateServerId = privateServerId }
			local result = documents.transaction(actor, function(data)
				data.reservation = data.reservation or reservation
				return { ok = true, reservation = data.reservation }
			end)
			local released = documents.releaseActor(actor)
			return if result.ok and released.ok then result.reservation else nil, result.reason or released.reason
		end,
	}
end

return M
