--!strict
-- EN/KO copy for the recovered screens (RecoveredScreens.luau). Every key mirrors a
-- games/robango-island/locale/strings.csv row (scr.*); RecoveredScreens.spec checks the mirror.
local M = {}
local strings: { [string]: { string } } = {
	["scr.arrival.continue"] = { "Continue", "계속" },
	["scr.arrival.goal"] = { "First goal: %s", "첫 목표: %s" },
	["scr.arrival.premise"] = {
		"You washed ashore on a wild island of dinosaurs.",
		"공룡이 사는 야생의 섬에 도착했어요.",
	},
	["scr.arrival.skip"] = { "Skip arrival", "도착 장면 건너뛰기" },
	["scr.arrival.skip_note"] = {
		"Skipping only skips the arrival scene. Your progress stays the same.",
		"건너뛰기는 도착 장면만 건너뛰어요. 진행은 그대로예요.",
	},
	["scr.arrival.title"] = { "Welcome to Robango", "로반고 섬에 오신 것을 환영해요" },
	["scr.arrival.together"] = {
		"Gather, craft, build, explore together.",
		"함께 채집하고, 만들고, 짓고, 탐험하세요.",
	},
	["scr.back"] = { "Back", "뒤로" },
	["scr.clan.none"] = {
		"You are not in a clan. Create or join one first.",
		"아직 부족이 없어요. 먼저 부족을 만들거나 가입하세요.",
	},
	["scr.clan.open"] = { "Open clan", "부족 열기" },
	["scr.confirm"] = { "Confirm", "확인" },
	["scr.layout.route"] = { "Route %d, stage %d", "항로 %d, %d단계" },
	["scr.layout.rw.brawl"] = { "Brawl arena", "난투장" },
	["scr.layout.rw.explore10"] = { "Wilds", "야생 지대" },
	["scr.layout.rw.explore20"] = { "Deep wilds", "깊은 야생 지대" },
	["scr.layout.rw.frontier30"] = { "Frontier", "외곽 섬" },
	["scr.layout.rw.frontier40"] = { "Snow frontier", "설원 외곽 섬" },
	["scr.layout.rw.frontier50"] = { "Volcanic frontier", "화산 외곽 섬" },
	["scr.layout.rw.frontier60"] = { "Rex frontier", "티라노 외곽 섬" },
	["scr.layout.rw.harbor"] = { "Harbor", "항구" },
	["scr.layout.rw.home"] = { "Home island", "개인 섬" },
	["scr.layout.rw.onboarding"] = { "Starting island", "시작 섬" },
	["scr.layout.rw.team-outpost"] = { "Team outpost", "팀 전초기지" },
	["scr.layout.unknown"] = { "Unnamed island", "이름 없는 섬" },
	["scr.library.count"] = {
		"%d saved score(s). Every revision is kept unchanged.",
		"저장한 악보 %d개. 모든 판은 바뀌지 않고 보관돼요.",
	},
	["scr.library.empty"] = {
		"No saved scores yet. Write one in the editor or import JSON.",
		"저장한 악보가 없어요. 편집기에서 만들거나 JSON을 가져오세요.",
	},
	["scr.library.ensemble"] = { "Play selected score together", "선택한 악보로 합주" },
	["scr.library.import"] = { "Import score", "악보 가져오기" },
	["scr.library.loading"] = { "Loading your scores...", "악보를 불러오는 중..." },
	["scr.library.new"] = { "New score (editor)", "새 악보 (편집기)" },
	["scr.library.row"] = { "%s rev %d - tempo %d, %d part(s), %ds", "%s %d판 - 템포 %d, 파트 %d개, %d초" },
	["scr.library.selected"] = { "Selected: %s", "선택됨: %s" },
	["scr.library.share"] = { "Share selected score", "선택한 악보 공유" },
	["scr.library.shared"] = {
		"Scores shared with you open by their ID in Import.",
		"공유받은 악보는 가져오기에서 ID로 열어요.",
	},
	["scr.library.title"] = { "Score library", "악보 보관함" },
	["scr.manage.blocked"] = { "Can't recover floor %d %s: %s", "%d층 %s 회수 불가: %s" },
	["scr.manage.confirm"] = {
		"Recover floor %d %s? The kit returns to your bag.",
		"%d층 %s을(를) 회수할까요? 부재는 가방으로 돌아와요.",
	},
	["scr.manage.done"] = { "Recovered.", "회수했어요." },
	["scr.manage.door"] = { "door", "문" },
	["scr.manage.empty"] = {
		"Nothing built yet. Place parts from Building or Build.",
		"아직 지은 것이 없어요. 건축이나 건설에서 부재를 놓으세요.",
	},
	["scr.manage.floor"] = { "floor", "바닥" },
	["scr.manage.floors"] = { "Multistorey parts: %d (version %d)", "다층 부재: %d개 (버전 %d)" },
	["scr.manage.home"] = { "Island structures: %d", "섬 구조물: %d개" },
	["scr.manage.move"] = { "Pack and move home...", "포장하고 집 이전..." },
	["scr.manage.part"] = { "Recover floor %d %s at %d, %d", "%d층 %s 회수 (%d, %d)" },
	["scr.manage.pillar"] = { "pillar", "기둥" },
	["scr.manage.roof"] = { "roof", "지붕" },
	["scr.manage.stairs"] = { "stairs", "계단" },
	["scr.manage.structure"] = { "Recover %s", "%s 회수" },
	["scr.manage.structure_blocked"] = { "Can't recover %s: %s", "%s 회수 불가: %s" },
	["scr.manage.structure_confirm"] = {
		"Recover %s? The kit goes to island storage.",
		"%s을(를) 회수할까요? 부재는 섬 창고로 가요.",
	},
	["scr.manage.title"] = { "Manage buildings", "건물 관리" },
	["scr.manage.wall"] = { "wall", "벽" },
	["scr.nav.arrival"] = { "Welcome", "시작 안내" },
	["scr.nav.library"] = { "Score library", "악보 보관함" },
	["scr.nav.manage"] = { "Manage buildings", "건물 관리" },
	["scr.nav.players"] = { "Players", "플레이어" },
	["scr.nav.research"] = { "Clan research", "부족 연구" },
	["scr.nav.territory"] = { "Territory", "영토" },
	["scr.nav.tracker"] = { "Recipe tracker", "제작 추적" },
	["scr.nav.treasury"] = { "Clan treasury", "부족 금고" },
	["scr.refuse.ALREADY_FINISHED"] = {
		"Already finished: complete it instead.",
		"이미 끝났어요: 완료를 누르세요.",
	},
	["scr.refuse.BUILD_BOUNDARY"] = {
		"Stand on your island, near the part.",
		"내 섬에서 부재 가까이 서세요.",
	},
	["scr.refuse.BUILD_PERMISSION"] = { "Only the island owner can do that.", "섬 주인만 할 수 있어요." },
	["scr.refuse.FORBIDDEN"] = { "You don't have permission for that.", "권한이 없어요." },
	["scr.refuse.FULL_SLOTS"] = { "Island storage is full.", "섬 창고가 가득 찼어요." },
	["scr.refuse.INSUFFICIENT_FUNDS"] = { "Not enough shellmoney.", "조개돈이 부족해요." },
	["scr.refuse.INVALID_TARGET"] = {
		"That player is already in the clan or invited.",
		"이미 부족원이거나 초대한 플레이어예요.",
	},
	["scr.refuse.INVALID_TERRITORY"] = {
		"That island can't be clan territory.",
		"그 섬은 부족 영토가 될 수 없어요.",
	},
	["scr.refuse.JOB_SETTLED"] = { "Already settled.", "이미 처리됐어요." },
	["scr.refuse.NOT_FRIEND"] = {
		"Only friends can visit that camp.",
		"친구만 그 캠프에 방문할 수 있어요.",
	},
	["scr.refuse.NOT_MEMBER"] = { "You are not a member.", "구성원이 아니에요." },
	["scr.refuse.NOT_READY"] = { "Not finished yet.", "아직 끝나지 않았어요." },
	["scr.refuse.OCCUPIED_STORAGE"] = { "Empty the storage first.", "먼저 보관함을 비우세요." },
	["scr.refuse.OUT_OF_RANGE"] = { "Go to your island first.", "먼저 내 섬으로 가세요." },
	["scr.refuse.PLOT_OCCUPIED"] = { "Harvest or clear the plot first.", "먼저 밭을 수확하거나 비우세요." },
	["scr.refuse.RESEARCH_EXISTS"] = { "That research already started.", "이미 시작한 연구예요." },
	["scr.refuse.RESEARCH_GATE"] = {
		"Needs the clan level and a clan hall on the clan territory.",
		"부족 레벨과 부족 영토의 부족 회관이 필요해요.",
	},
	["scr.refuse.REVISION_CONFLICT"] = {
		"Something changed meanwhile. Check and try again.",
		"그사이 바뀌었어요. 확인 후 다시 시도하세요.",
	},
	["scr.refuse.STAIRS_REQUIRED"] = {
		"An upper floor would lose its stairs.",
		"위층으로 가는 계단이 끊겨요.",
	},
	["scr.refuse.STALE_VERSION"] = {
		"The building changed. Try again.",
		"건물이 바뀌었어요. 다시 시도하세요.",
	},
	["scr.refuse.SUPPORT_REQUIRED"] = {
		"Parts above rest on it. Recover them first.",
		"위에 놓인 부재가 받치고 있어요. 먼저 회수하세요.",
	},
	["scr.refuse.TODO_LIMIT"] = { "Too many tracked recipes.", "추적 중인 제작법이 너무 많아요." },
	["scr.refuse.TRANSFER_CONFLICT"] = {
		"A different transfer is already settling.",
		"다른 이체가 정산 중이에요.",
	},
	["scr.refuse.UNKNOWN_PART"] = { "That part is gone.", "그 부재는 이미 없어요." },
	["scr.refuse.UNKNOWN_STRUCTURE"] = { "That structure is gone.", "그 구조물은 이미 없어요." },
	["scr.refuse.unknown"] = { "Could not complete. Try again.", "완료하지 못했어요. 다시 시도하세요." },
	["scr.research.advanced-capture"] = { "Advanced capture", "고급 포획" },
	["scr.research.cancel"] = { "Cancel %s (refund %d)", "%s 취소 (환불 %d)" },
	["scr.research.capture_off"] = {
		"Advanced capture works only while your clan holds the team outpost.",
		"고급 포획은 부족이 팀 전초기지를 보유할 때만 적용돼요.",
	},
	["scr.research.capture_on"] = {
		"Advanced capture is active: your clan holds the team outpost.",
		"고급 포획 효과 적용 중: 부족이 팀 전초기지를 보유 중이에요.",
	},
	["scr.research.combat"] = { "Combat", "전투" },
	["scr.research.complete"] = { "Complete %s", "%s 완료" },
	["scr.research.done"] = { "%s: researched", "%s: 연구 완료" },
	["scr.research.exploration"] = { "Exploration", "탐험" },
	["scr.research.hall"] = {
		"Research runs in a clan hall on the clan territory.",
		"연구는 부족 영토의 부족 회관에서 진행돼요.",
	},
	["scr.research.locked_funds"] = { "Needs %d shellmoney in the treasury", "금고에 조개돈 %d 필요" },
	["scr.research.locked_level"] = { "Needs clan level %d", "부족 레벨 %d 필요" },
	["scr.research.locked_role"] = {
		"Only the owner and officers start research",
		"연구는 부족장과 간부만 시작해요",
	},
	["scr.research.ready"] = { "%s: finished, tap Complete", "%s: 끝났어요, 완료를 누르세요" },
	["scr.research.row"] = { "%s: clan level %d, %d shellmoney, %d min", "%s: 부족 레벨 %d, 조개돈 %d, %d분" },
	["scr.research.running"] = { "%s: in progress, %s left", "%s: 진행 중, %s 남음" },
	["scr.research.start"] = { "Start %s", "%s 시작" },
	["scr.research.summary"] = { "Clan level %d - funds %d shellmoney", "부족 레벨 %d - 자금 조개돈 %d" },
	["scr.research.title"] = { "Clan research", "부족 연구" },
	["scr.social.access"] = { "Home access...", "집 출입 권한..." },
	["scr.social.clan"] = { "Invite %s to clan", "%s님 부족 초대" },
	["scr.social.clan_open"] = { "Clan...", "부족..." },
	["scr.social.count"] = { "%d/%d players on this server", "이 서버 플레이어 %d/%d명" },
	["scr.social.empty"] = {
		"No other players here yet. Friends who join this server appear here.",
		"아직 다른 플레이어가 없어요. 이 서버에 들어온 친구가 여기에 표시돼요.",
	},
	["scr.social.party"] = { "Invite %s to party", "%s님 파티 초대" },
	["scr.social.player"] = { "%s", "%s" },
	["scr.social.sent"] = { "Sent.", "보냈어요." },
	["scr.social.title"] = { "Players", "플레이어" },
	["scr.social.trade"] = { "Trade with %s", "%s님과 거래" },
	["scr.social.visit"] = { "Visit %s's camp", "%s님 캠프 방문" },
	["scr.status.cancelled"] = { "cancelled, half refunded", "취소됨, 절반 환불" },
	["scr.status.completed"] = { "completed", "완료" },
	["scr.status.done"] = { "done", "완료" },
	["scr.status.pending"] = { "settling", "정산 중" },
	["scr.status.refused"] = { "refused", "거절됨" },
	["scr.territory.claim"] = { "Make %s the clan territory", "%s을(를) 부족 영토로 지정" },
	["scr.territory.clan"] = { "Clan territory: %s", "부족 영토: %s" },
	["scr.territory.clan_none"] = { "Clan territory: not claimed", "부족 영토: 아직 없음" },
	["scr.territory.confirm"] = {
		"Move the clan territory to %s? The change is recorded.",
		"부족 영토를 %s(으)로 옮길까요? 변경은 기록돼요.",
	},
	["scr.territory.entry"] = { "%s ago: %s -> %s", "%s 전: %s -> %s" },
	["scr.territory.here"] = { "You are on %s.", "현재 위치: %s" },
	["scr.territory.journal"] = { "Territory changes", "영토 변경 기록" },
	["scr.territory.journal_empty"] = { "No territory changes yet.", "아직 영토 변경 기록이 없어요." },
	["scr.territory.nobody"] = { "none", "없음" },
	["scr.territory.outpost"] = { "Team outpost: %s holds it, %s left", "팀 전초기지: %s 보유, %s 남음" },
	["scr.territory.outpost_none"] = { "Team outpost: nobody holds it", "팀 전초기지: 보유한 부족 없음" },
	["scr.territory.personal"] = { "Your island: %s, land rank %d", "내 섬: %s, 토지 등급 %d" },
	["scr.territory.personal_none"] = {
		"Your island has not loaded yet.",
		"내 섬 정보를 아직 불러오지 못했어요.",
	},
	["scr.territory.rules"] = {
		"Your island follows your home access rules. Clan territory is where the clan hall and clan research work.",
		"내 섬은 집 출입 권한을 따라요. 부족 회관과 부족 연구는 부족 영토에서 작동해요.",
	},
	["scr.territory.title"] = { "Territory", "영토" },
	["scr.tracker.empty"] = {
		"No tracked recipes. Mark a recipe as to-do in Craft.",
		"추적 중인 제작법이 없어요. 제작에서 할 일로 표시하세요.",
	},
	["scr.tracker.input"] = { "%s: bag %d + storage %d / need %d", "%s: 가방 %d + 창고 %d / 필요 %d" },
	["scr.tracker.limit"] = { "Up to %d recipes can be tracked.", "최대 %d개 제작법을 추적할 수 있어요." },
	["scr.tracker.missing"] = { "%s: %d item(s) short", "%s: 재료 %d개 부족" },
	["scr.tracker.open_craft"] = { "Open Craft", "제작 열기" },
	["scr.tracker.output"] = { "Makes %s x%d", "결과: %s %d개" },
	["scr.tracker.ready"] = { "%s: ready to craft", "%s: 바로 제작 가능" },
	["scr.tracker.short"] = {
		"%s: bag %d + storage %d / need %d (short %d)",
		"%s: 가방 %d + 창고 %d / 필요 %d (부족 %d)",
	},
	["scr.tracker.title"] = { "Recipe tracker", "제작 추적" },
	["scr.tracker.untrack"] = { "Stop tracking %s", "%s 추적 해제" },
	["scr.treasury.amount"] = { "Amount: %d (tap to change)", "금액: %d (눌러서 변경)" },
	["scr.treasury.balance"] = { "Your shellmoney: %d", "내 조개돈: %d" },
	["scr.treasury.can_withdraw"] = { "You may withdraw from the treasury.", "금고에서 출금할 수 있어요." },
	["scr.treasury.confirm_deposit"] = {
		"Deposit %d shellmoney into the clan treasury?",
		"부족 금고에 조개돈 %d을 입금할까요?",
	},
	["scr.treasury.confirm_withdraw"] = {
		"Withdraw %d shellmoney from the clan treasury?",
		"부족 금고에서 조개돈 %d을 출금할까요?",
	},
	["scr.treasury.deposit"] = { "Deposit %d", "%d 입금" },
	["scr.treasury.done"] = { "Done. The treasury is updated.", "완료했어요. 금고가 갱신됐어요." },
	["scr.treasury.entry_deposit"] = { "Deposit %d by %s: %s", "%s 입금 %d: %s" },
	["scr.treasury.entry_withdraw"] = { "Withdraw %d by %s: %s", "%s 출금 %d: %s" },
	["scr.treasury.funds"] = { "Clan funds: %d shellmoney", "부족 자금: 조개돈 %d" },
	["scr.treasury.ledger"] = { "Recent treasury activity", "최근 금고 기록" },
	["scr.treasury.ledger_empty"] = { "No deposits or withdrawals yet.", "아직 입출금 기록이 없어요." },
	["scr.treasury.no_withdraw"] = {
		"Withdrawing needs permission from the clan owner.",
		"출금하려면 부족장의 허가가 필요해요.",
	},
	["scr.treasury.spend"] = { "Research %s: -%d (%s)", "연구 %s: -%d (%s)" },
	["scr.treasury.title"] = { "Clan treasury", "부족 금고" },
	["scr.treasury.withdraw"] = { "Withdraw %d", "%d 출금" },
}

local function ko(locale: string): boolean
	return string.sub(locale, 1, 2) == "ko"
end

function M.keys(): { string }
	local out = {}
	for key in strings do
		table.insert(out, key)
	end
	table.sort(out)
	return out
end

function M.has(key: string): boolean
	return strings[key] ~= nil
end

function M.text(locale: string, key: string, ...: any): string
	local row = strings[key]
	if not row then
		return key
	end
	local template = row[if ko(locale) then 2 else 1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

function M.refusal(locale: string, reason: string?): string
	local key = "scr.refuse." .. tostring(reason)
	return M.text(locale, if strings[key] then key else "scr.refuse.unknown")
end

--- Player-facing island name for a layout id (never the raw id).
function M.layout(locale: string, id: string?): string
	if type(id) ~= "string" or id == "" then
		return M.text(locale, "scr.territory.nobody")
	end
	local route, stage = string.match(id, "^rw%.a(%d+)%.s(%d+)$")
	if route then
		return M.text(locale, "scr.layout.route", tonumber(route), tonumber(stage))
	end
	return M.text(locale, if strings["scr.layout." .. id] then "scr.layout." .. id else "scr.layout.unknown")
end

--- "1:05" / "2h 03m" style remaining time.
function M.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours, minutes = seconds // 3600, (seconds % 3600) // 60
	return if hours > 0
		then string.format("%dh %02dm", hours, minutes)
		else string.format("%d:%02d", minutes, seconds % 60)
end

return M
