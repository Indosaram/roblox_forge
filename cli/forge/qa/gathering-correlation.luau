--!strict
-- Forge QA gather correlation: one source of truth for the client-side request/result
-- correlation a gather step is proven with. The Studio gameplay driver embeds this module
-- verbatim in the emitted client code and calls its factory with the real services; the Lune
-- fixture at cli/forge/fixtures/gathering-client/correlation.luau requires the same module and
-- drives the same event ordering, so the two cannot drift and the correlation is verified by
-- running it rather than by matching its text. The module itself reads no Roblox global: every
-- engine object arrives through the injected context, so it is ordinary typed Luau that the
-- repository's own analysis runs on.
--
-- The correlation is per dispatch: it records the request identity the real client publishes for
-- this step's injected input (ForgeGatherRequested fires on every activation, including the
-- replay of a request the client has not settled) and accepts only a result that carries that
-- identity, so a result for a still-unresolved request is correlated with the input that caused
-- it while a result for a dispatch this step never made is refused.
local M = {}

-- Bounded, decode-free evidence log. Ids are appended newest-last and the string is trimmed from the
-- front at a comma boundary, so the newest identities always survive and the attribute cannot grow. Only
-- the string library is used, so this stays ordinary typed Luau with no Roblox global.
local function bounded(log: any, piece: string): string
	local text = if type(log) == "string" then log else ""
	local nextText = if #text == 0 then piece else text .. "," .. piece
	if #nextText > 240 then
		local cut = #nextText - 240
		local comma = string.find(nextText, ",", cut, true)
		nextText = if comma then string.sub(nextText, comma + 1) else string.sub(nextText, -240)
	end
	return nextText
end

function M.install(
	ctx: {
		input: any,
		prompt: any,
		keyE: any,
		now: () -> number,
		encode: (any) -> string,
	},
	m: any,
	target: any,
	nodeId: string,
	relay: any,
	requested: any,
	connections: { any }
)
	m:SetAttribute("Attempt", 0)
	m:SetAttribute("Input", false)
	m:SetAttribute("InputAt", false)
	m:SetAttribute("Triggered", false)
	m:SetAttribute("Packets", 0)
	m:SetAttribute("Relevant", 0)
	m:SetAttribute("RequestId", false)
	m:SetAttribute("DispatchAt", false)
	m:SetAttribute("Captured", false)
	-- Bounded identity evidence, so a failure can be attributed without another live run: whether the
	-- client held a durable policy when it was asked to dispatch, the dispatch identities it published,
	-- and every relay packet identity with whether it matched the identity current at that moment.
	-- Nothing here retries, waits, or reads credentials; it only records what the real client published.
	m:SetAttribute("PolicyReady", false)
	m:SetAttribute("RequestIdLog", "")
	m:SetAttribute("PacketIdLog", "")
	table.insert(
		connections,
		ctx.input.InputBegan:Connect(function(i)
			if i.KeyCode == ctx.keyE then
				m:SetAttribute("Input", true)
				m:SetAttribute("InputAt", ctx.now())
			end
		end)
	)
	table.insert(
		connections,
		ctx.prompt.PromptTriggered:Connect(function(prompt)
			if prompt == target then
				m:SetAttribute("Triggered", true)
			end
		end)
	)
	table.insert(
		connections,
		requested.Event:Connect(function(packet)
			-- The real client activation's own dispatch telemetry with the server time of the
			-- dispatch. It is published on every activation, so the identity the correlation
			-- uses is always the one the client itself holds for this step's input.
			if packet.nodeId == nodeId and type(packet.requestId) == "string" then
				m:SetAttribute("RequestId", packet.requestId)
				m:SetAttribute("DispatchAt", packet.serverTime)
				-- The client only reaches this fire when it holds a durable policy, so this records readiness
				-- rather than asserting it.
				m:SetAttribute("PolicyReady", true)
				m:SetAttribute("RequestIdLog", bounded(m:GetAttribute("RequestIdLog"), packet.requestId))
			end
		end)
	)
	table.insert(
		connections,
		relay.Event:Connect(function(packet)
			m:SetAttribute("Packets", (m:GetAttribute("Packets") or 0) + 1)
			local requestId = m:GetAttribute("RequestId")
			-- Every packet identity is recorded with whether it matched the identity current at that instant,
			-- which is what distinguishes "the client never dispatched" from "a packet arrived unmatched".
			local matched = if type(requestId) == "string" and packet.requestId == requestId then "1" else "0"
			m:SetAttribute(
				"PacketIdLog",
				bounded(
					m:GetAttribute("PacketIdLog"),
					tostring(packet.requestId)
						.. "="
						.. matched
						.. ":"
						.. tostring(
							type(packet.result) == "table"
									and (packet.result.reason or (type(packet.result.data) == "table" and packet.result.data.status) or packet.result.ok)
								or "?"
						)
				)
			)
			-- The service-level trigger event is recorded as evidence, never required: its order
			-- against the client's own synchronous dispatch is not guaranteed and gating on it
			-- drops a real confirmation. The result must instead carry the identity of the
			-- dispatch this step's input caused.
			if
				packet.nodeId == nodeId
				and m:GetAttribute("Input") == true
				and type(requestId) == "string"
				and packet.requestId == requestId
			then
				m:SetAttribute("Relevant", (m:GetAttribute("Relevant") or 0) + 1)
				local captured = m:GetAttribute("Captured")
				-- Pending is a legitimate intermediate result: it must reach the marker so the
				-- driver can activate the same request again instead of waiting forever. A result
				-- whose identity is neither the captured one nor a fresh one the driver cleared
				-- for a settled request is refused, never mistaken for the current request.
				if type(packet.requestId) ~= "string" or (captured ~= false and captured ~= packet.requestId) then
					m.Value = "INVALID"
				else
					m:SetAttribute("Captured", packet.requestId)
					m.Value = ctx.encode(packet)
				end
			end
		end)
	)
end

return M
