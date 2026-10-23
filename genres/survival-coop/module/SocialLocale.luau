--!strict
-- Player-facing copy for the social/home/trade sheets (EN default, KO for ko-*).
-- Mirrored into games/robango-island/locale/strings.csv.
local M = {}
local strings: { [string]: { string } } = {
	["perm.title"] = { "Home access", "집 출입 권한" },
	["perm.owner"] = { "Owner: %s", "소유자: %s" },
	["perm.me"] = { "Me", "나" },
	["perm.version"] = { "Save version %d", "저장 버전 %d" },
	["perm.visit"] = { "Visit: %s", "방문: %s" },
	["perm.use"] = { "Use: %s", "사용: %s" },
	["perm.build"] = { "Build: %s", "건설: %s" },
	["perm.recover"] = { "Recover: %s", "회수: %s" },
	["perm.offline"] = { "Help while I am offline: %s", "오프라인 중 도움: %s" },
	["perm.hint"] = { "Tap a row to change who may do it.", "줄을 눌러 허용 대상을 바꾸세요." },
	["perm.move"] = { "Move home...", "집 이전..." },
	["mode.owner"] = { "Only me", "나만" },
	["mode.none"] = { "Nobody else", "다른 사람 없음" },
	["mode.friend"] = { "Friends", "친구" },
	["mode.clan"] = { "Clan", "부족" },
	["on"] = { "On", "켜짐" },
	["off"] = { "Off", "꺼짐" },
	["move.title"] = { "Move home", "집 이전" },
	["move.current"] = { "Current spot: %s", "현재 위치: %s" },
	["move.pick"] = { "Move to %s", "%s(으)로 이전" },
	["move.confirm_head"] = { "Move to %s?", "%s(으)로 이전할까요?" },
	["move.packed"] = { "Packed: %d stored stacks, %d structures", "포장: 보관 묶음 %d개, 구조물 %d개" },
	["move.kept"] = {
		"Access grants and property history are kept.",
		"출입 권한과 소유 기록은 유지됩니다.",
	},
	["move.history"] = { "Moves so far: %d", "지금까지 이전: %d회" },
	["move.lock"] = {
		"Storage transfers in progress lock the move.",
		"보관 이동이 진행 중이면 이전할 수 없습니다.",
	},
	["move.do"] = { "Confirm move", "이전 확인" },
	["move.done"] = { "Home moved. Grants kept.", "집을 옮겼습니다. 권한은 유지됩니다." },
	["back"] = { "Back", "뒤로" },
	["dest.cove-north"] = { "North cove", "북쪽 만" },
	["dest.cove-east"] = { "East cove", "동쪽 만" },
	["dest.cove-south"] = { "South cove", "남쪽 만" },
	["siege.title"] = { "Team siege", "팀 공성전" },
	["siege.rules"] = {
		"%d-%d vs %d-%d clan members, %d minutes. Hold the centre %d seconds in total.",
		"부족원 %d-%d 대 %d-%d, %d분. 중앙을 총 %d초 점령하세요.",
	},
	["siege.roster"] = { "%s: %d queued (%s)", "%s: 대기 %d명 (%s)" },
	["siege.ready"] = { "ready", "준비 완료" },
	["siege.waiting"] = { "needs %d", "%d명 필요" },
	["siege.empty"] = { "No clan is queued yet.", "아직 대기 중인 부족이 없습니다." },
	["siege.you_queued"] = { "You are in the queue.", "대기열에 있습니다." },
	["siege.queue"] = { "Join queue", "대기열 참가" },
	["siege.leave_queue"] = { "Leave queue", "대기열 나가기" },
	["siege.owner"] = { "Outpost owner: %s (%s left)", "거점 소유: %s (남은 시간 %s)" },
	["siege.no_owner"] = { "Outpost owner: none", "거점 소유: 없음" },
	["match.title"] = { "Siege match", "공성전 경기" },
	["match.team"] = { "%s: %d players, control %d/%d s", "%s: %d명, 점령 %d/%d초" },
	["match.timer"] = { "Time left %s", "남은 시간 %s" },
	["match.leave"] = { "Leave match", "경기 나가기" },
	["match.confirm"] = {
		"Leave? You stop counting toward control; your team plays on.",
		"나갈까요? 점령에 더 이상 기여하지 않고 팀은 계속합니다.",
	},
	["match.leave_yes"] = { "Yes, leave match", "네, 나가기" },
	["match.stay"] = { "Stay", "남기" },
	["result.title"] = { "Siege result", "공성전 결과" },
	["result.win"] = { "%s won the outpost.", "%s 부족이 거점을 차지했습니다." },
	["result.tie"] = { "Draw. No new owner.", "무승부. 새 소유자가 없습니다." },
	["result.own"] = { "Owned for 24 hours (%s left).", "24시간 소유 (남은 시간 %s)." },
	["result.prev_kept"] = {
		"Previous owner %s keeps its original expiry (%s left).",
		"이전 소유 부족 %s의 기존 만료가 유지됩니다 (남은 시간 %s).",
	},
	["result.prev_ended"] = {
		"Previous owner %s lost the outpost.",
		"이전 소유 부족 %s의 소유가 끝났습니다.",
	},
	["result.prev_none"] = { "There was no previous owner.", "이전 소유자가 없었습니다." },
	["result.research_on"] = {
		"Your clan's advanced capture research is active while it owns the outpost.",
		"거점을 소유한 동안 부족의 고급 포획 연구가 적용됩니다.",
	},
	["result.research_off"] = {
		"Advanced capture needs clan research and outpost ownership.",
		"고급 포획에는 부족 연구와 거점 소유가 필요합니다.",
	},
	["result.continue"] = { "Continue", "계속" },
	["tx.title"] = { "Transactions", "거래 정산" },
	["tx.op"] = { "Ref %s", "참조 %s" },
	["tx.verifying"] = { "Verifying...", "확인 중..." },
	["tx.settling"] = { "Settling. Nothing is charged twice.", "정산 중. 두 번 청구되지 않습니다." },
	["tx.delivered"] = { "Delivered.", "전달 완료." },
	["tx.rejected"] = { "Rejected: %s", "거절됨: %s" },
	["tx.check"] = { "Check status", "상태 확인" },
	["tx.close"] = { "Close (keeps settling)", "닫기 (정산은 계속)" },
	["tx.none"] = { "No settlement in progress.", "진행 중인 정산이 없습니다." },
	["trade.title"] = { "Direct trade", "직접 거래" },
	["trade.invite"] = { "Trade with %s", "%s님과 거래" },
	["trade.nobody"] = { "No other player on this server.", "이 서버에 다른 플레이어가 없습니다." },
	["trade.with"] = { "Trading with %s (offer %d)", "%s님과 거래 중 (제안 %d)" },
	["trade.yours"] = { "You give: %s", "내가 줌: %s" },
	["trade.theirs"] = { "You get: %s", "내가 받음: %s" },
	["trade.nothing"] = { "nothing", "없음" },
	["trade.item"] = { "%s x%d (Q%d, dur %d, Lv%d)", "%s x%d (품질%d, 내구%d, Lv%d)" },
	["trade.coins"] = { "%d shellmoney", "조개돈 %d" },
	["trade.pick"] = { "Item: %s", "물건: %s" },
	["trade.qty"] = { "Quantity %d (tap +1)", "수량 %d (눌러서 +1)" },
	["trade.coins_step"] = { "Coins %d (tap +10)", "조개돈 %d (눌러서 +10)" },
	["trade.update"] = { "Update my offer", "내 제안 갱신" },
	["trade.confirm"] = { "Confirm trade", "거래 확인" },
	["trade.confirmed"] = { "Confirmed: you %s, them %s", "확인: 나 %s, 상대 %s" },
	["trade.cancel"] = { "Cancel trade", "거래 취소" },
	["trade.settled"] = { "Trade complete.", "거래 완료." },
	["trade.cancelled"] = { "Trade cancelled: %s", "거래 취소됨: %s" },
	["trade.changes"] = {
		"Any change clears both confirmations.",
		"변경하면 양쪽 확인이 모두 해제됩니다.",
	},
	["yes"] = { "yes", "예" },
	["no"] = { "no", "아니요" },
	["dialogue.title"] = { "Talk", "대화" },
	["dialogue.continue"] = { "Continue", "계속" },
	["dialogue.complete"] = { "Complete: %s", "완료: %s" },
	["dialogue.service"] = { "Open: %s", "열기: %s" },
	["dialogue.bye"] = { "Goodbye", "작별 인사" },
	["dialogue.done"] = { "Checkpoint saved.", "체크포인트를 저장했습니다." },
	["npc.marit"] = {
		"Marit: Contracts come and go with the tide. Pick one you can finish.",
		"마리트: 계약은 물때처럼 오가요. 끝낼 수 있는 걸 고르세요.",
	},
	["npc.tuck"] = {
		"Tuck: Bring sound materials and the bench will do the rest.",
		"턱: 좋은 재료만 가져오면 작업대가 나머지를 해요.",
	},
	["npc.hop"] = {
		"Hop: Every page of your journal is a place you have been.",
		"홉: 일지의 한 장 한 장이 당신이 다녀온 곳이에요.",
	},
	["npc.sella"] = {
		"Sella: Prices here are set by islanders, not by me.",
		"셀라: 여기 가격은 제가 아니라 섬 사람들이 정해요.",
	},
	["npc.bram"] = {
		"Bram: A clan shares funds and research. Outposts are a separate contest.",
		"브램: 부족은 자금과 연구를 나눠요. 거점은 별개의 경쟁이에요.",
	},
	["npc.ines"] = {
		"Ines: Rest, eat, and patch yourself up before the next crossing.",
		"이네스: 다음 항해 전에 쉬고, 먹고, 몸을 추스르세요.",
	},
	["npc.pip"] = {
		"Pip: Passes and kits are fixed; you always know what you get.",
		"핍: 패스와 키트는 정해져 있어요. 무엇을 받을지 늘 알 수 있죠.",
	},
	["npc.station.workbench"] = {
		"Workbench: Clamps, a vise and a tray of loose fittings. Assembly work starts here.",
		"작업대: 죔쇠와 바이스, 부품 접시가 놓여 있어요. 조립은 여기서 시작해요.",
	},
	["npc.station.relay"] = {
		"Radio hut: Static crackles in the headset. A lens would sharpen it.",
		"무전 오두막: 헤드셋에서 잡음이 지직거려요. 렌즈가 있으면 또렷해질 거예요.",
	},
	["npc.station.market"] = {
		"Market board: Islanders pin their offers here. Every price is set by a player.",
		"시장 게시판: 섬 사람들이 내놓은 물건이 붙어 있어요. 가격은 모두 플레이어가 정해요.",
	},
	["npc.default"] = { "The harbor keeper nods at you.", "항구 관리인이 고개를 끄덕입니다." },
	["service.contracts"] = { "Contracts", "계약" },
	["service.craft"] = { "Crafting", "제작" },
	["service.journal"] = { "Journal", "일지" },
	["service.clan-membership"] = { "Clan membership", "부족 가입" },
	["service.shop"] = { "Shop", "상점" },
	["service.market"] = { "Market", "시장" },
	["service.organizations"] = { "Organizations", "조직" },
	["org.title"] = { "Organizations", "조직" },
	["org.intro"] = {
		"Each finished mission objective earns 20 trust with its organization.",
		"임무 목표를 하나 마칠 때마다 해당 조직의 신뢰가 20 오릅니다.",
	},
	["org.wayfarers"] = { "Wayfarers", "길잡이회" },
	["org.scholars"] = { "Scholars", "학자회" },
	["org.wardens"] = { "Wardens", "수호대" },
	["org.traders"] = { "Traders", "상인회" },
	["org.wayfarers.missions"] = { "Gather missions (Marit)", "채집 임무 (마리트)" },
	["org.scholars.missions"] = { "Craft and survey missions (Bram)", "제작·조사 임무 (브램)" },
	["org.wardens.missions"] = { "Rescue and hunt missions (Ines)", "구조·사냥 임무 (이네스)" },
	["org.traders.missions"] = { "Transport missions (Pip)", "운송 임무 (핍)" },
	["org.rank"] = { "Trust rank %d/5", "신뢰 등급 %d/5" },
	["org.next"] = { "%d/%d to next rank", "다음 등급까지 %d/%d" },
	["org.max"] = { "Highest rank reached", "최고 등급 달성" },
	["refuse.FORBIDDEN"] = { "Only the owner may do that.", "소유자만 할 수 있습니다." },
	["refuse.CLAN_REQUIRED"] = {
		"Join a clan before granting clan access.",
		"부족 권한을 주려면 먼저 부족에 가입하세요.",
	},
	["refuse.INVALID_PERMISSIONS"] = {
		"That access setting is not allowed.",
		"허용되지 않는 권한 설정입니다.",
	},
	["refuse.OUT_OF_RANGE"] = { "Go to your own island first.", "먼저 내 섬으로 가세요." },
	["refuse.SAME_DESTINATION"] = { "Your home is already there.", "집이 이미 그곳에 있습니다." },
	["refuse.UNKNOWN_DESTINATION"] = { "That spot is not available.", "그 위치는 사용할 수 없습니다." },
	["refuse.TRANSFER_LOCKED"] = {
		"A storage transfer is still settling. Try again after it finishes.",
		"보관 이동이 아직 정산 중입니다. 끝난 뒤 다시 시도하세요.",
	},
	["refuse.NOT_TEAM_MEMBER"] = {
		"Only clan members can queue for the siege.",
		"부족원만 공성전 대기열에 들어갈 수 있습니다.",
	},
	["refuse.MATCH_ACTIVE"] = { "You are already in a match.", "이미 경기 중입니다." },
	["refuse.NOT_IN_MATCH"] = { "You are not in this match.", "이 경기에 참가하고 있지 않습니다." },
	["refuse.SELF_TRADE"] = { "You cannot trade with yourself.", "자신과는 거래할 수 없습니다." },
	["refuse.DIFFERENT_SERVER"] = {
		"That player is not on this server.",
		"그 플레이어는 이 서버에 없습니다.",
	},
	["refuse.TRADE_BUSY"] = { "That player is already trading.", "그 플레이어는 이미 거래 중입니다." },
	["refuse.STALE_REVISION"] = {
		"The offer changed. Review it again.",
		"제안이 바뀌었습니다. 다시 확인하세요.",
	},
	["refuse.EMPTY_TRADE"] = { "Offer something first.", "먼저 무언가를 제안하세요." },
	["refuse.INSUFFICIENT_ITEMS"] = { "You no longer have those items.", "그 물건이 더 이상 없습니다." },
	["refuse.INSUFFICIENT_FUNDS"] = { "Not enough shellmoney.", "조개돈이 부족합니다." },
	["refuse.TRADE_CLOSED"] = { "This trade is closed.", "이 거래는 닫혔습니다." },
	["refuse.COUNTERPART_LEFT"] = { "The other player left.", "상대가 떠났습니다." },
	["refuse.NO_TRADE"] = { "No open trade.", "열린 거래가 없습니다." },
	["refuse.UNKNOWN_OPERATION"] = {
		"The server has no record of this yet. Check again shortly.",
		"서버에 아직 기록이 없습니다. 잠시 뒤 다시 확인하세요.",
	},
	["refuse.WRONG_OBJECTIVE"] = { "Nothing to report here yet.", "아직 여기서 보고할 것이 없습니다." },
	["refuse.OUT_OF_REACH"] = { "Step closer first.", "더 가까이 가세요." },
	["refuse.COMMAND_UNAVAILABLE"] = { "Not available right now.", "지금은 사용할 수 없습니다." },
	["refuse.unknown"] = {
		"Could not complete. Check status and try again.",
		"완료하지 못했습니다. 상태를 확인하세요.",
	},
}

local function ko(locale: string): boolean
	return string.sub(locale, 1, 2) == "ko"
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
	local key = "refuse." .. tostring(reason)
	return M.text(locale, if strings[key] then key else "refuse.unknown")
end

function M.duration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local hours, minutes = seconds // 3600, (seconds % 3600) // 60
	return if hours > 0
		then string.format("%dh %02dm", hours, minutes)
		else string.format("%d:%02d", minutes, seconds % 60)
end

M.strings = strings
return M
