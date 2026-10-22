--!strict
local M = {}

local strings: { [string]: { string } } = {
	nav_title = { "Menu", "메뉴" },
	nav_open = { "Open menu", "메뉴 열기" },
	nav_survival = { "Survival", "생존" },
	nav_craft = { "Craft", "제작" },
	nav_build = { "Build", "건설" },
	nav_skills = { "Skills", "기술" },
	nav_journal = { "Journal", "일지" },
	nav_explore = { "Explore", "탐험" },
	nav_social = { "Social", "함께" },
	nav_market = { "Market", "장터" },
	nav_music = { "Music", "연주" },
	nav_import = { "Import score", "악보 가져오기" },
	nav_share = { "Share score", "악보 공유" },
	nav_ensemble = { "Ensemble", "합주" },
	nav_inbox = { "Inbox", "수령함" },
	nav_settings = { "Settings", "설정" },
	nav_locked = { "%s: %s", "%s: %s" },
	lock_unknown = { "Not on this island", "이 섬에는 없어요" },
	lock_unavailable = { "Not available right now", "지금은 쓸 수 없어요" },
	lock_inbox = { "Coming later: receipts go to your bag", "준비 중: 받은 물건은 가방으로 가요" },
	lock_unsaved = { "Save a score first", "먼저 악보를 저장하세요" },
	import_title = { "Import score", "악보 가져오기" },
	import_hint = {
		"Paste score JSON (version 1, 480 ticks per beat, up to 256 KiB)",
		"악보 JSON을 붙여 넣으세요 (버전 1, 박당 480틱, 최대 256 KiB)",
	},
	import_check = { "Check score", "악보 확인" },
	import_save = { "Save score", "악보 저장" },
	import_preview = { "Tempo %d, %d parts, %d notes, %ds", "템포 %d, 파트 %d개, 음표 %d개, %d초" },
	import_saved = { "Saved %s", "저장됨 %s" },
	import_lookup = { "Score ID (like 123:score:1#2)", "악보 ID (예: 123:score:1#2)" },
	import_use = { "Use this score ID", "이 악보 ID 사용" },
	import_selected = { "Selected %s", "선택됨 %s" },
	share_title = { "Share score", "악보 공유" },
	share_ref = { "Score ID: %s", "악보 ID: %s" },
	share_note = {
		"Copy the ID above. Nothing is posted or opened for you.",
		"위 ID를 복사하세요. 자동으로 게시하거나 열지 않아요.",
	},
	share_recipient = { "Player user ID", "플레이어 사용자 ID" },
	share_send = { "Share with player", "플레이어와 공유" },
	share_done = { "Shared %s", "공유됨 %s" },
	lobby_title = { "Ensemble", "합주" },
	lobby_score = { "Score %s (locked revision)", "악보 %s (고정된 판)" },
	lobby_none = { "No score selected", "선택한 악보 없음" },
	lobby_slot = { "%d. %s - part %d%s", "%d. %s - 파트 %d%s" },
	lobby_empty = { "%d. Open", "%d. 빈 자리" },
	lobby_ready_tag = { " (ready)", " (준비)" },
	lobby_host_tag = { " (host)", " (방장)" },
	lobby_part = { "Part %d", "파트 %d" },
	lobby_in_range = { "Near a fire: you can join", "모닥불 근처: 참여할 수 있어요" },
	lobby_out_range = { "Stand within 16 studs of a campfire", "모닥불 16스터드 안에 서세요" },
	lobby_join = { "Join with part %d", "파트 %d로 참여" },
	lobby_ready = { "Ready", "준비" },
	lobby_unready = { "Not ready", "준비 취소" },
	lobby_start = { "Start (host)", "시작 (방장)" },
	lobby_leave = { "Leave", "나가기" },
	lobby_prompt = { "Ensemble", "합주" },
	play_countdown = { "Starting in %.1f s", "%.1f초 후 시작" },
	play_progress = { "Part %d: %d/%d notes", "파트 %d: 음표 %d/%d" },
	play_sync = { "In sync with the server clock", "서버 시계에 맞춰 연주 중" },
	play_late = { "Joined late: finished notes skipped", "늦게 합류: 지난 음표는 건너뜀" },
	play_rejoin = { "Rejoin part %d", "파트 %d로 재합류" },
	play_leave = { "Leave ensemble", "합주 나가기" },
	["score.bytes"] = { "Too large: the limit is 256 KiB", "너무 커요: 최대 256 KiB" },
	["score.utf8"] = { "Text must be UTF-8", "UTF-8 텍스트여야 해요" },
	["score.json"] = { "Not valid JSON", "올바른 JSON이 아니에요" },
	["score.version"] = {
		"Needs version 1 and only version, tempo, parts",
		"버전 1과 version, tempo, parts만 필요해요",
	},
	["score.tempo"] = { "Tempo must be a whole number from 40 to 200", "템포는 40~200 정수여야 해요" },
	["score.parts"] = { "Needs 1 to 6 parts", "파트는 1~6개여야 해요" },
	["score.field"] = { "Part %d note %d: %s", "파트 %d 음표 %d: %s" },
	["score.partfield"] = { "Part %d: %s", "파트 %d: %s" },
	f_instrumentId = { "unknown instrument", "알 수 없는 악기" },
	f_notes = { "too many notes or bad list", "음표가 너무 많거나 목록이 잘못됨" },
	f_polyphony = { "more than 8 notes at once", "동시에 8음 초과" },
	f_startTick = { "start is outside the 3 minute score", "시작이 3분 범위를 벗어남" },
	f_durationTicks = { "length runs past the end", "길이가 끝을 넘음" },
	f_pitch = { "pitch must be 21 to 108", "음높이는 21~108" },
	f_velocity = { "velocity must be 1 to 127", "세기는 1~127" },
	f_note = { "unexpected note fields", "음표 항목이 잘못됨" },
	["score.ref"] = { "Enter an ID like 123:score:1#2", "123:score:1#2 형식의 ID를 입력하세요" },
	["score.ref_url"] = {
		"That is a link. Enter the score ID, not a URL",
		"링크예요. URL이 아니라 악보 ID를 입력하세요",
	},
	["score.recipient"] = {
		"Enter the player's numeric user ID",
		"플레이어의 숫자 사용자 ID를 입력하세요",
	},
	["score.self"] = { "You already own this score", "이미 내 악보예요" },
	["score.owner"] = { "Only the owner can share this revision", "이 판은 주인만 공유할 수 있어요" },
	["score.private"] = { "This score has not been shared with you", "공유받지 않은 악보예요" },
	["score.missing"] = { "That score revision does not exist", "그 악보 판이 없어요" },
	["score.unsaved"] = { "Save a score first", "먼저 악보를 저장하세요" },
	["score.store_unavailable"] = {
		"Score storage is busy. Try again soon",
		"악보 저장소가 바빠요. 잠시 후 다시",
	},
	["score.library_full"] = { "Your score library is full", "악보 보관함이 가득 찼어요" },
	["ensemble.range"] = {
		"Stand within 16 studs of a campfire with an instrument",
		"악기를 들고 모닥불 16스터드 안에 서세요",
	},
	["ensemble.part"] = { "That part is not in this score", "이 악보에 없는 파트예요" },
	["ensemble.revision"] = {
		"The ensemble is playing a different score",
		"합주가 다른 악보를 쓰고 있어요",
	},
	["ensemble.full"] = { "All six places are taken", "여섯 자리가 모두 찼어요" },
	["ensemble.part_taken"] = { "Someone already plays that part", "다른 사람이 그 파트를 맡았어요" },
	["ensemble.playing"] = { "The performance has started", "연주가 이미 시작됐어요" },
	["ensemble.lobby"] = { "Join the ensemble first", "먼저 합주에 참여하세요" },
	["ensemble.host"] = { "Only the host can start", "방장만 시작할 수 있어요" },
	["ensemble.not_ready"] = {
		"Everyone must be ready and near the fire",
		"모두 준비하고 모닥불 근처에 있어야 해요",
	},
	["ensemble.member"] = { "You are not in the ensemble", "합주에 참여하지 않았어요" },
	failed = { "That did not work. Try again", "실패했어요. 다시 시도하세요" },
}

M.strings = strings

local function ko(locale: string): boolean
	return string.sub(locale, 1, 2) == "ko"
end

function M.text(locale: string, key: string, ...: any): string
	local entry = strings[key]
	if entry == nil then
		return key
	end
	local template = if ko(locale) then entry[2] else entry[1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

function M.refusal(locale: string, reason: string?): string
	local value = reason or ""
	if strings[value] then
		return M.text(locale, value)
	end
	local part, note, field = string.match(value, "^score%.parts%[(%d+)%]%.notes%[(%d+)%]%.?(%a*)$")
	if part and note then
		local key = "f_" .. (if field == nil or field == "" then "note" else field)
		return M.text(locale, "score.field", tonumber(part), tonumber(note), M.text(locale, key))
	end
	local only, partField = string.match(value, "^score%.parts%[(%d+)%]%.(%a+)$")
	if only and partField and strings["f_" .. partField] then
		local key = "f_" .. partField
		return M.text(locale, "score.partfield", tonumber(only), M.text(locale, key))
	end
	return M.text(locale, "failed")
end

return M
