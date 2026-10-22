--!strict
-- Locale keys travel with server prompts; each client renders its own language.
local M = {}
local strings: { [string]: { string } } = {
	open = { "Open", "열기" },
	interact = { "Interact", "대화 / 이용" },
	market = { "Market", "장터" },
	travel = { "Travel", "이동" },
	home = { "Home", "개인 섬" },
	archipelago = { "Archipelago", "군도" },
	["next-island"] = { "Next island", "다음 섬" },
	["island-rank"] = { "Island rank", "섬 등급" },
	modify = { "Modify", "개조" },
	["technical-support"] = { "Technical support", "기술 지원" },
	warehouse_open = { "Open warehouse", "창고 열기" },
	warehouse = { "Warehouse", "창고" },
	journal_checkpoint = { "Journal checkpoint", "일지 확인" },
	journal = { "Journal", "일지" },
	survey = { "Survey", "조사" },
	farm = { "Farm", "농사" },
	["farm-plot"] = { "Farm plot", "밭" },
	["bandage-claim"] = { "Take bandage", "붕대 받기" },
	["rescue-treat"] = { "Treat castaway", "표류자 치료" },
	["cargo-claim"] = { "Pick up cargo", "화물 받기" },
	["cargo-deliver"] = { "Deliver cargo", "화물 전달" },
	["npc.marit"] = { "Marit", "마릿" },
	["npc.tuck"] = { "Tuck", "턱" },
	["npc.hop"] = { "Hop", "홉" },
	["npc.sella"] = { "Sella", "셀라" },
	["npc.bram"] = { "Bram", "브램" },
	["npc.ines"] = { "Ines", "이네스" },
	["npc.pip"] = { "Pip", "핍" },
	["station.workbench.t1"] = { "Workbench", "작업대" },
	["station.campfire.t1"] = { "Campfire", "모닥불" },
	guide = { "Harbor guide", "항구 안내" },
	hazard = { "Harbor lookout", "항구 전망대" },
	resources = { "Supplies", "보급품" },
	objective = { "Market board", "장터 게시판" },
	["practice-seedbed"] = { "Practice seedbed", "연습용 모판" },
	["practice-fiber-stitch"] = { "Weaving practice", "섬유 엮기 연습" },
	["visitor-portal"] = { "Home portal", "개인 섬 이동문" },
	["rescue-beacon"] = { "Rescue beacon", "구조 신호기" },
	["station.signal-relay.t1"] = { "Signal relay", "신호 중계기" },
}
M.strings = strings
function M.text(locale: string, key: string): string
	local entry = strings[key] or strings.guide
	return entry[if string.sub(locale, 1, 2) == "ko" then 2 else 1]
end
function M.bind(prompt: any, action: string, object: string?)
	prompt:SetAttribute("ForgeActionKey", action)
	prompt.ActionText = M.text("en-us", action)
	if object then
		prompt:SetAttribute("ForgeObjectKey", object)
		prompt.ObjectText = M.text("en-us", object)
	end
end
function M.localize(prompt: any, locale: string)
	local action, object = prompt:GetAttribute("ForgeActionKey"), prompt:GetAttribute("ForgeObjectKey")
	if action then
		prompt.ActionText = M.text(locale, action)
	end
	if object then
		prompt.ObjectText = M.text(locale, object)
	end
end
return M
