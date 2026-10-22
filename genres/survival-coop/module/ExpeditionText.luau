--!strict
-- Player-facing text for the expedition lane (routes, party, invites, departure, travel,
-- expedition tracker, results, hazard, knockout). EN first, ko-kr second; default EN.
-- Every key mirrors a games/robango-island/locale/strings.csv row.
local M = {}

local strings: { [string]: { string } } = {
	exp_routes = { "Routes", "항로" },
	exp_party = { "Party", "파티" },
	exp_route = { "Route %d: %s", "항로 %d: %s" },
	exp_route_gate = { "Level %d, rank %d, %d stages, %d missions", "레벨 %d, 등급 %d, %d단계, 미션 %d개" },
	exp_route_cap = { "Up to %d players. Closes in %s", "최대 %d명. %s 후 마감" },
	exp_choose = { "Choose", "선택" },
	exp_locked = { "Locked", "잠김" },
	exp_depart_title = { "Depart to route %d?", "항로 %d로 출발할까요?" },
	exp_depart_body = {
		"Stage 1 of 4. Party ready: %s. Closes in %s. You return to your home island.",
		"4단계 중 1단계. 파티 준비: %s. %s 후 마감. 돌아오면 내 섬으로 가요.",
	},
	exp_confirm = { "Confirm", "확인" },
	exp_stay = { "Stay", "머무르기" },
	exp_yes = { "yes", "예" },
	exp_no = { "no", "아니요" },
	exp_travel = { "Connecting to route %d...", "항로 %d에 연결하는 중..." },
	exp_retry = { "Retry", "다시 시도" },
	exp_stage = { "Route %d - stage %d of 4", "항로 %d - 4단계 중 %d단계" },
	exp_objective = { "%s %s: %d/%d", "%s %s: %d/%d" },
	exp_expires = { "Route closes in %s", "%s 후 항로 마감" },
	exp_next = { "Next island", "다음 섬" },
	exp_next_locked = {
		"Finish both objectives to unlock the next island",
		"목표 두 개를 마치면 다음 섬이 열려요",
	},
	exp_home = { "Return home", "집으로 돌아가기" },
	exp_results = { "Expedition results", "탐험 결과" },
	exp_result_row = { "%s: XP %d, coins %d, trust %d (%s)", "%s: 경험치 %d, 코인 %d, 신뢰 %d (%s)" },
	exp_first = { "first clear", "첫 완료" },
	exp_repeat = { "repeat", "반복" },
	exp_delivered = { "Rewards delivered", "보상 지급 완료" },
	exp_pending = { "Rewards on the way", "보상 지급 중" },
	exp_no_results = { "No rewards earned this time", "이번에는 받은 보상이 없어요" },
	exp_status_complete = { "Every island on this route is done", "이 항로의 섬을 모두 마쳤어요" },
	exp_status_expired = { "The route closed before you finished", "끝내기 전에 항로가 닫혔어요" },
	exp_status_return = { "You returned home early", "일찍 집으로 돌아왔어요" },
	party_members = { "Members %d/%d", "멤버 %d/%d" },
	party_leader = { "leader", "리더" },
	party_ready = { "ready", "준비됨" },
	party_not_ready_tag = { "not ready", "준비 안 됨" },
	party_empty = {
		"No party yet. Invite a player to start one.",
		"아직 파티가 없어요. 플레이어를 초대해 만드세요.",
	},
	party_invite = { "Invite %s", "%s 초대" },
	party_remove = { "Remove %s", "%s 내보내기" },
	party_leave = { "Leave party", "파티 나가기" },
	party_share = { "Share route %d", "항로 %d 공유" },
	party_shared = { "Shared route: %d", "공유한 항로: %d" },
	party_note = {
		"A party only travels together. It shares no storage or building rights.",
		"파티는 함께 이동만 해요. 창고와 건설 권한은 나누지 않아요.",
	},
	invite_title = { "%s invites you", "%s님의 초대" },
	invite_body = {
		"Route %s, %d/%d members. Expires in %s. Your gate: %s",
		"항로 %s, 멤버 %d/%d. %s 후 만료. 내 조건: %s",
	},
	invite_any = { "not chosen", "미정" },
	invite_accept = { "Accept", "수락" },
	invite_decline = { "Decline", "거절" },
	hazard_title = { "Hazard: %s", "위험: %s" },
	hazard_body = { "Intensity %d. Stay out of the marked area.", "강도 %d. 표시된 구역을 피하세요." },
	hazard_volcano = {
		"Heat: -%d HP/s, +%d fatigue/s. Lava boots halve it. Hot springs are a refuge.",
		"열기: 체력 -%d/초, 피로 +%d/초. 용암 장화가 절반으로 줄여요. 온천은 피난처예요.",
	},
	hazard_refuge = { "Refuge: you are safe here", "피난처: 여기서는 안전해요" },
	ko_title = { "You are down", "쓰러졌어요" },
	ko_wait = { "Back on your feet in %d s", "%d초 뒤 다시 일어나요" },
	ko_safe = {
		"Safe zone: your bag, cargo and pets stay yours",
		"안전 구역: 가방, 화물, 동물은 그대로예요",
	},
	ko_danger = {
		"Danger zone: your bag dropped here. Others can take it after ten minutes.",
		"위험 구역: 가방을 여기에 떨어뜨렸어요. 열 분 뒤 다른 사람도 가져갈 수 있어요.",
	},
	ko_pet = { "%s is resting: %ds, or feed it once", "%s 휴식 중: %d초, 또는 먹이 한 번" },
	ko_feed = { "Feed", "먹이 주기" },
	exp_refused = { "Not possible right now. Try again.", "지금은 할 수 없어요. 다시 시도하세요." },
	reason_level_gate = { "Your level is too low for this route", "이 항로에는 레벨이 부족해요" },
	reason_development_gate = { "Raise your island development rank first", "섬 개발 등급을 먼저 올리세요" },
	reason_instability_gate = { "Clear the previous route first", "이전 항로를 먼저 완료하세요" },
	reason_route_expired = { "This route has closed", "이 항로는 닫혔어요" },
	reason_expiry_imminent = {
		"No new entry in the final ten minutes",
		"마지막 10분에는 새로 들어갈 수 없어요",
	},
	reason_expedition_active = { "You are already on an expedition", "이미 탐험 중이에요" },
	reason_party_not_leader = { "Only the party leader can do that", "파티 리더만 할 수 있어요" },
	reason_party_not_ready = {
		"A party member does not meet the route gate",
		"조건을 못 채운 파티원이 있어요",
	},
	reason_party_full = { "The party is full (8 players)", "파티가 가득 찼어요 (8명)" },
	reason_party_member_busy = { "That player is already in a party", "그 플레이어는 이미 파티에 있어요" },
	reason_invite_expired = { "The invite has expired", "초대가 만료됐어요" },
	reason_invite_missing = { "The invite is no longer valid", "초대가 더 이상 유효하지 않아요" },
	reason_player_offline = { "That player is not on this server", "그 플레이어는 이 서버에 없어요" },
	reason_mission_gate = { "Finish both objectives first", "목표 두 개를 먼저 마치세요" },
	reason_missing_expedition = { "You are not on an expedition", "탐험 중이 아니에요" },
}

M.strings = strings

function M.text(locale: string, key: string, ...: any): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local template = if string.sub(locale, 1, 2) == "ko" then entry[2] else entry[1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

function M.reason(locale: string, reason: string?): string
	local key = "reason_" .. tostring(reason)
	return M.text(locale, if strings[key] then key else "exp_refused")
end

function M.duration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s >= 3600 then
		return string.format("%dh %02dm", s // 3600, (s % 3600) // 60)
	end
	return string.format("%d:%02d", s // 60, s % 60)
end

return M
