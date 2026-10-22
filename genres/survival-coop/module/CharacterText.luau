--!strict
-- EN/KO text for the character/progression screens. Keys mirror games/robango-island/locale/strings.csv
-- (char_*). Refusal reasons map to sentences; a raw reason code is never shown.
local M = {}

local strings: { [string]: { string } } = {
	char_title = { "Character", "캐릭터" },
	char_level = { "Level %d / %d", "레벨 %d / %d" },
	char_xp = { "XP %d / %d to next level", "다음 레벨까지 경험치 %d / %d" },
	char_xp_max = { "Maximum level reached", "최고 레벨 달성" },
	char_sp = { "SP %d available / %d total", "SP %d 사용 가능 / 총 %d" },
	char_rank = { "Exploration rank %d / 10", "탐험 등급 %d / 10" },
	char_awards = { "First awards earned %d / %d", "첫 달성 보상 %d / %d" },
	char_open_rank = { "Island rank", "섬 등급" },
	char_open_reset = { "Reset skills", "기술 초기화" },
	char_open_equipment = { "Equipment", "장비" },
	char_open_research = { "Personal research", "개인 연구" },
	reset_title = { "Skill reset", "기술 초기화" },
	reset_refund = { "Refund: %d SP", "환급: SP %d" },
	reset_nodes = { "Removes %d learned skills", "배운 기술 %d개 제거" },
	reset_none = { "No learned skills to reset", "초기화할 기술이 없어요" },
	reset_keep = { "Mastery and crafted gear are kept", "숙련도와 만든 장비는 유지돼요" },
	reset_busy_note = { "Not during combat or crafting", "전투·제작 중에는 불가" },
	reset_confirm = { "Confirm reset", "초기화 확인" },
	reset_done = { "Skills reset. SP refunded", "기술을 초기화하고 SP를 돌려받았어요" },
	rank_title = { "Island rank", "섬 등급" },
	rank_points = { "Development %d (100 per rank)", "개발 점수 %d (등급당 100)" },
	rank_next = { "Next rank at %d", "다음 등급: %d" },
	rank_max = { "Highest rank reached", "최고 등급 달성" },
	rank_lab_open = { "Laboratory unlocked (rank %d)", "연구실 해금 (등급 %d)" },
	rank_lab_locked = { "Laboratory unlocks at rank %d", "연구실은 등급 %d에 해금" },
	rank_guide = { "Finish island missions to earn development", "섬 임무를 마치면 개발 점수를 얻어요" },
	rank_award = { "%s +%d", "%s +%d" },
	rank_award_done = { "Done: %s +%d", "완료: %s +%d" },
	research_title = { "Personal research", "개인 연구" },
	research_line_life = { "Life (climate): %d%%", "생활(기후): %d%%" },
	research_line_light = { "Light work: %d%%", "가벼운 작업: %d%%" },
	research_line_heavy = { "Heavy carry: %d%%", "무거운 운반: %d%%" },
	research_tier = { "T%d %d%% · %d coins · %s · %ds", "T%d %d%% · 조개돈 %d · %s · %d초" },
	research_start = { "Start", "시작" },
	research_cancel = { "Cancel (refund %d)", "취소 (환급 %d)" },
	research_complete = { "Collect", "받기" },
	research_done = { "Done", "완료" },
	research_running = { "Running, ready in %ds", "진행 중, %d초 남음" },
	support_title = { "Technical support", "기술 지원" },
	support_gate = { "Requires level %d (you are %d)", "레벨 %d 필요 (현재 %d)" },
	support_item = { "Item: %s", "장비: %s" },
	support_none = { "Equip an item first", "먼저 장비를 착용하세요" },
	support_current = { "Current effect +%d%%", "현재 효과 +%d%%" },
	support_tier = { "Tier %d: +%d%% · %d coins · %s", "%d단계: +%d%% · 조개돈 %d · %s" },
	support_confirm = { "Confirm tier %d", "%d단계 확인" },
	modify_title = { "Modify", "개조" },
	modify_slot = { "Slot %d: %s", "슬롯 %d: %s" },
	modify_empty = { "empty", "비어 있음" },
	modify_warning = { "Replacing a slot gives no refund", "슬롯을 바꾸면 환급되지 않아요" },
	modify_row = { "+2 %s · %s", "+2 %s · %s" },
	modify_apply = { "Apply to slot %d", "슬롯 %d에 적용" },
	equip_title = { "Equipment", "장비" },
	equip_slot = { "%s: %s", "%s: %s" },
	equip_stats = { "Power %s · Armor %d · Cold %s · Heat %s", "공격 %s · 방어 %d · 추위 %s · 더위 %s" },
	equip_button = { "Equip %s (%s)", "%s 착용 (%s)" },
	equip_unequip = { "Unequip %s", "%s 벗기" },
	equip_modify = { "Modify %s", "%s 개조" },
	equip_support = { "Support %s", "%s 기술 지원" },
	equip_tier = { "Tech tier %d · mods %d/2", "기술 단계 %d · 개조 %d/2" },
	slot_head = { "Head", "머리" },
	slot_top = { "Top", "상의" },
	slot_bottom = { "Bottom", "하의" },
	slot_shoes = { "Shoes", "신발" },
	slot_gloves = { "Gloves", "장갑" },
	slot_bag = { "Bag", "가방" },
	slot_weapon = { "Weapon/tool", "무기·도구" },
	attr_sharpness = { "sharpness", "날카로움" },
	attr_hardness = { "hardness", "단단함" },
	attr_insulation = { "insulation", "보온" },
	attr_flexibility = { "flexibility", "유연성" },
	char_working = { "Sending...", "보내는 중..." },
	-- Refusals.
	STALE_QUOTE = {
		"Your skills changed. Check the new refund",
		"기술이 바뀌었어요. 새 환급량을 확인하세요",
	},
	RESET_BUSY = { "Finish combat and crafting first", "전투와 제작을 먼저 끝내세요" },
	CHARACTER_LEVEL_GATE = { "Your level is too low", "레벨이 부족해요" },
	SKILL_GATE = { "Learn the required skill first", "필요한 기술을 먼저 배우세요" },
	DEVELOPMENT_GATE = { "Raise your island rank first", "섬 등급을 먼저 올리세요" },
	STATION_GATE = { "Stand next to the right station", "알맞은 시설 옆에 서세요" },
	INSUFFICIENT_COINS = { "Not enough coins", "조개돈이 부족해요" },
	INSUFFICIENT_MATERIALS = { "Not enough materials in your bag", "가방에 재료가 부족해요" },
	UPGRADE_PREREQUISITE = { "Finish the previous tier first", "이전 단계를 먼저 끝내세요" },
	ALREADY_COMPLETED = { "Already done", "이미 완료했어요" },
	JOB_PENDING = { "Another job is still running", "다른 작업이 아직 진행 중이에요" },
	NOT_READY = {
		"Still running. Collect when the timer ends",
		"아직 진행 중이에요. 시간이 끝나면 받으세요",
	},
	JOB_FINISHED = { "Already finished. Collect it instead", "이미 끝났어요. 대신 받으세요" },
	CANNOT_CANCEL = { "This job cannot be cancelled", "이 작업은 취소할 수 없어요" },
	INELIGIBLE_EQUIPMENT = { "This item cannot take that", "이 장비에는 쓸 수 없어요" },
	UNKNOWN_EQUIPMENT = { "Equip the item first", "장비를 먼저 착용하세요" },
	ITEM_NOT_OWNED = { "That item is not in your bag", "가방에 그 물건이 없어요" },
	NOT_EQUIPMENT = { "That item cannot be worn", "착용할 수 없는 물건이에요" },
	ITEM_BROKEN = { "Repair the item first", "먼저 장비를 수리하세요" },
	ITEM_RESERVED = { "That item is in use by a job", "작업에 쓰이는 중인 물건이에요" },
	ALREADY_EQUIPPED = { "Already equipped", "이미 착용 중이에요" },
	SLOT_EMPTY = { "Nothing equipped there", "그 칸에는 장비가 없어요" },
	NOT_ALIVE = { "You cannot do this while down", "쓰러진 동안은 할 수 없어요" },
	char_failed = { "That did not work. Try again", "실패했어요. 다시 시도하세요" },
}

M.keys = {} :: { string }
for key in strings do
	table.insert(M.keys, key)
end
table.sort(M.keys)

function M.has(key: string): boolean
	return strings[key] ~= nil
end

function M.text(locale: string, key: string): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	return if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
end

function M.format(locale: string, key: string, ...: any): string
	return string.format(M.text(locale, key), ...)
end

function M.refusal(locale: string, reason: string?): string
	local key = reason or ""
	return M.text(locale, if strings[key] and string.upper(key) == key then key else "char_failed")
end

return M
