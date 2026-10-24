--!strict
-- ui.brawl-lobby / ui.brawl-match / ui.brawl-results in one docked sheet. Rendered through the
-- shared SocialSheet (ui-kit modalSheet inside the fitted extension rect), so the brawl screen
-- uses the same header, close button, fonts, colours and wrapped 48px rows as every other panel.
-- `rows(locale, model, policy, act)` is pure: one labelled fact per row, localized weather names
-- with their ui.icon.weather.* art, and explicit empty, waiting and unavailable states.
local Match = require("../../../core/domain/brawl/Match")
local Sheet = require("./SocialSheet")
local M = {}

local strings: { [string]: { string } } = {
	brawl_title = { "Brawl", "난투" },
	brawl_unavailable = {
		"Brawl is available on a brawl server. Travel there from the harbor.",
		"난투 서버에서만 이용할 수 있어요. 항구에서 난투 서버로 이동하세요.",
	},
	brawl_rules = {
		"Entry: level %d or higher, %d-%d players, %d s ready phase.",
		"참가 조건: 레벨 %d 이상, %d-%d명, 준비 시간 %d초.",
	},
	brawl_snapshot = {
		"Snapshot equipment only. Original equipment is not consumed.",
		"복제 장비만 사용합니다. 원본 장비는 소모되지 않습니다.",
	},
	brawl_reward_line = {
		"Rewards: participation %d, victory %d coins (first %d matches per day).",
		"보상: 참가 %d, 승리 %d 코인 (하루 처음 %d경기).",
	},
	brawl_queue_status = { "Waiting room: %d/%d players", "대기실: %d/%d명" },
	brawl_queue_empty = {
		"No one is waiting yet. Join and the match starts once %d players are in.",
		"아직 대기 중인 사람이 없어요. 참가 후 %d명이 모이면 경기가 시작돼요.",
	},
	brawl_queue_need = {
		"%d more player(s) needed to start.",
		"시작까지 %d명이 더 필요해요.",
	},
	brawl_queue_you = { "You are in the waiting room.", "대기실에 있어요." },
	brawl_preparing = { "Get ready: the match starts in %s.", "준비하세요: %s 후 경기가 시작돼요." },
	brawl_active = { "Match in progress: %d alive, %s left.", "경기 중: 생존 %d명, 남은 시간 %s." },
	brawl_weather_now = { "Weather: %s. %s", "날씨: %s. %s" },
	brawl_weather_next = { "Next weather: %s in %s.", "다음 날씨: %s, %s 후." },
	brawl_weather_plan = {
		"Weather changes every %d s, ending with a closing ring.",
		"날씨가 %d초마다 바뀌고 마지막에 경계가 좁혀져요.",
	},
	brawl_radius = { "Safe zone radius: %d studs.", "안전 구역 반경: %d스터드." },
	brawl_spectator = {
		"You are out. Spectating until the match ends.",
		"탈락했어요. 경기가 끝날 때까지 관전합니다.",
	},
	brawl_result_win = { "Victory! You are the last survivor.", "승리! 마지막 생존자입니다." },
	brawl_result_draw = { "Draw. No single survivor.", "무승부. 단독 생존자가 없어요." },
	brawl_result_eliminated = {
		"Eliminated. Better luck next match.",
		"탈락. 다음 경기에서 다시 도전하세요.",
	},
	brawl_result_watch = { "Match over.", "경기가 끝났어요." },
	brawl_settled = { "Reward received: %d coins.", "보상 수령: %d 코인." },
	brawl_join = { "Join queue", "대기열 참가" },
	brawl_leave = { "Leave", "나가기" },
	brawl_claim = { "Claim result", "결과 받기" },
	brawl_ok = { "Confirmed", "확인됨" },
	brawl_attack = { "Attack nearest rival", "가까운 상대 공격" },
	brawl_ranged = { "Shoot nearest rival", "가까운 상대 사격" },
	brawl_dodge = { "Dodge", "회피" },
	brawl_guard = { "Guard", "방어" },
	weather_clear = { "Clear", "맑음" },
	weather_rain = { "Rain", "비" },
	weather_fog = { "Fog", "안개" },
	weather_storm = { "Storm", "폭풍" },
	weather_collapse = { "Closing ring", "경계 수축" },
	effect_clear = { "No weather effects.", "날씨 효과가 없어요." },
	effect_rain = { "Sprinting costs %d%% more stamina.", "질주 기력 소모가 %d%% 늘어요." },
	effect_fog = { "Ranged attacks reach only %d studs.", "원거리 공격이 %d스터드까지만 닿아요." },
	effect_storm = { "Mounts are unavailable.", "탈것에 탈 수 없어요." },
	effect_collapse = {
		"The safe zone shrinks. Outside it you lose %d%% max HP per second.",
		"안전 구역이 줄어들어요. 밖에서는 초당 최대 체력의 %d%%를 잃어요.",
	},
	NO_AMMO = { "No snapshot ammunition", "복제 탄약이 없습니다" },
	LEVEL_REQUIRED = { "Required level not reached", "참가 레벨이 부족합니다" },
	QUEUE_FULL = { "Queue full", "대기열이 가득 찼습니다" },
	QUEUE_CLOSED = { "Queue closed", "대기열이 마감되었습니다" },
	NOT_ACTIVE = { "Match has not started", "경기가 시작되지 않았습니다" },
	ELIMINATED = { "Eliminated: spectating", "탈락: 관전 중" },
	WEATHER_RANGE = { "Fog restricts range", "안개로 사거리가 제한됩니다" },
	WEATHER_MOUNT = { "Storm prevents mounting", "폭풍 중에는 탑승할 수 없습니다" },
	UNVERIFIED_ACTION = { "Action unavailable", "사용할 수 없는 행동입니다" },
	RECOVERY = { "Recovering", "회복 중" },
	PERSONAL_UNAVAILABLE = { "Settlement pending", "정산 대기 중" },
	COMMAND_PENDING = { "Previous command pending", "이전 명령 처리 중" },
	brawl_refused = { "Request refused", "요청 거절됨" },
}
M.strings = strings

function M.text(locale: string, key: string, ...: any): string
	local row = strings[key]
	if not row then
		return key
	end
	local template = row[if string.sub(locale, 1, 2) == "ko" then 2 else 1]
	return if select("#", ...) > 0 then string.format(template, ...) else template
end

function M.refusal(locale: string, reason: string?): string
	return M.text(locale, if reason and strings[reason] then reason else "brawl_refused")
end

function M.weatherName(locale: string, id: string): string
	return if strings["weather_" .. id] then M.text(locale, "weather_" .. id) else M.text(locale, "weather_clear")
end

-- ItemIcons.ui id: resolves to the manifest key ui-icon-weather-<id>.
function M.weatherIcon(id: string): string
	return "weather." .. id
end

local function effect(locale: string, weather: any, policy: any): string
	local id = weather.id
	if id == "rain" then
		return M.text(locale, "effect_rain", math.floor(((weather.sprintMultiplier or 1) - 1) * 100 + 0.5))
	elseif id == "fog" then
		return M.text(locale, "effect_fog", weather.rangeCap or 0)
	elseif id == "storm" then
		return M.text(locale, "effect_storm")
	elseif id == "collapse" then
		return M.text(locale, "effect_collapse", math.floor(policy.outsideDamageFraction * 100 + 0.5))
	end
	return M.text(locale, "effect_clear")
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

function M.model(state: any, actor: string, now: number, receipt: any): any
	local player = state.actors[actor]
	local alive = 0
	for _, participant in state.actors do
		if participant.alive then
			alive += 1
		end
	end
	local finished = state.phase == "finished"
	local remaining = if state.startsAt
		then math.max(
			0,
			math.ceil(state.startsAt + (if state.phase == "preparing" then 0 else state.policy.durationSeconds) - now)
		)
		else 0
	local weather = if state.startsAt then Match.weather(state, now) else state.policy.weather[1]
	local nextWeather = nil
	if state.startsAt and state.phase == "active" then
		local elapsed = now - state.startsAt
		for _, entry in state.policy.weather do
			if entry.at > elapsed then
				nextWeather = { id = entry.id, inSeconds = math.ceil(entry.at - elapsed) }
				break
			end
		end
	end
	return {
		phase = state.phase,
		queued = #state.order,
		minimum = state.policy.minimumPlayers,
		maximum = state.policy.maximumPlayers,
		minimumLevel = state.policy.minimumLevel,
		alive = alive,
		remaining = remaining,
		weather = weather.id,
		weatherEntry = weather,
		nextWeather = nextWeather,
		timeline = state.policy.weather,
		inMatch = player ~= nil,
		fighting = player ~= nil and player.alive and state.phase == "active",
		spectator = player ~= nil and not player.alive and not finished,
		result = if not finished
			then nil
			elseif state.winner == actor then "win"
			elseif not state.winner then "draw"
			elseif player then "eliminated"
			else "watch",
		join = state.phase == "queue" and not player,
		leave = player ~= nil and not finished,
		claim = finished and player ~= nil and not (receipt and receipt.ok),
		settlement = receipt,
		participationReward = state.policy.participationReward,
		winReward = state.policy.winReward,
		dailySettlements = state.policy.dailySettlements,
		radius = if state.startsAt
			then state.policy.initialRadius * math.clamp(
				(state.startsAt + state.policy.durationSeconds - now)
					/ (state.policy.durationSeconds - state.policy.collapseAt),
				0,
				1
			)
			else state.policy.initialRadius,
	}
end

-- act: join, leave, claim, combat(name). model nil = not on a brawl server.
function M.rows(locale: string, model: any?, policy: any, act: any, feedback: string?): { Sheet.Row }
	local function t(key: string, ...: any): string
		return M.text(locale, key, ...)
	end
	local rules =
		t("brawl_rules", policy.minimumLevel, policy.minimumPlayers, policy.maximumPlayers, policy.preparationSeconds)
	local rewards = t("brawl_reward_line", policy.participationReward, policy.winReward, policy.dailySettlements)
	if not model then
		return {
			{ text = t("brawl_unavailable") },
			{ text = rules },
			{ text = t("brawl_snapshot") },
			{ text = rewards },
		}
	end
	local rows: { Sheet.Row } = {}
	local function add(text: string, onClick: (() -> ())?, icon: string?)
		table.insert(rows, { text = text, onClick = onClick, icon = icon })
	end
	local first = policy.weather[1]
	if model.phase == "queue" then
		add(t("brawl_queue_status", model.queued, model.maximum))
		if model.queued == 0 then
			add(t("brawl_queue_empty", model.minimum))
		elseif model.queued < model.minimum then
			add(t("brawl_queue_need", model.minimum - model.queued))
		end
		add(rules)
		if model.inMatch then
			add(t("brawl_queue_you"))
		end
		add(t("brawl_snapshot"))
		add(rewards)
		add(
			t("brawl_weather_plan", if policy.weather[2] then policy.weather[2].at - first.at else 0),
			nil,
			M.weatherIcon(first.id)
		)
	elseif model.phase == "preparing" then
		add(t("brawl_preparing", clock(model.remaining)))
		add(t("brawl_queue_status", model.queued, model.maximum))
		add(
			t("brawl_weather_now", M.weatherName(locale, first.id), effect(locale, first, policy)),
			nil,
			M.weatherIcon(first.id)
		)
		add(t("brawl_snapshot"))
	elseif model.phase == "active" then
		add(t("brawl_active", model.alive, clock(model.remaining)))
		if model.spectator then
			add(t("brawl_spectator"))
		end
		local current = model.weatherEntry or first
		add(
			t("brawl_weather_now", M.weatherName(locale, current.id), effect(locale, current, policy)),
			nil,
			M.weatherIcon(current.id)
		)
		if model.nextWeather then
			add(
				t("brawl_weather_next", M.weatherName(locale, model.nextWeather.id), clock(model.nextWeather.inSeconds)),
				nil,
				M.weatherIcon(model.nextWeather.id)
			)
		end
		add(t("brawl_radius", math.floor(model.radius + 0.5)))
	else
		add(t("brawl_result_" .. (model.result or "watch")))
		add(rewards)
		if model.settlement and model.settlement.ok then
			add(t("brawl_settled", model.settlement.amount or 0))
		end
	end
	if feedback and feedback ~= "" then
		add(feedback)
	end
	if model.fighting then
		for _, name in { "attack", "ranged", "dodge", "guard" } do
			add(t("brawl_" .. name), function()
				act.combat(name)
			end)
		end
	end
	if model.join then
		add(t("brawl_join"), act.join)
	end
	if model.claim then
		add(t("brawl_claim"), act.claim)
	end
	if model.leave then
		add(t("brawl_leave"), act.leave)
	end
	return rows
end

function M.factory(ctx: any): any
	local env: any = getfenv()
	local players = if ctx.actorId then nil else env.game:GetService("Players")
	local actor = ctx.actorId or tostring(players.LocalPlayer.UserId)
	local now = ctx.serverNow or function(): number
		return env.game:GetService("Workspace"):GetServerTimeNow()
	end
	local target = ctx.target
		or function(state: any): string?
			local service = env.game:GetService("Players")
			local character = service.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				return nil
			end
			local nearest, distance = nil, math.huge
			for id, participant in state.actors do
				if id ~= actor and participant.alive then
					local player = service:GetPlayerByUserId(tonumber(id) or 0)
					local other = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if other and (other.Position - root.Position).Magnitude < distance then
						nearest, distance = id, (other.Position - root.Position).Magnitude
					end
				end
			end
			return nearest
		end
	local receipt: any = nil
	local matchId: string? = nil
	local feedback: string? = nil
	local panel: any
	local function current(): any
		return panel and panel.state() and panel.state().brawl
	end
	local function send(action: string, args: { any }): any
		local result = ctx.send("survival-coop:" .. action, args)
		feedback = if result.ok then M.text(ctx.locale, "brawl_ok") else M.refusal(ctx.locale, result.reason)
		return result
	end
	local act = {
		join = function()
			send("brawl-queue", {})
			panel.render()
		end,
		leave = function()
			send("brawl-leave", {})
			panel.render()
		end,
		claim = function()
			local result = send("brawl-reward", {})
			if result.ok then
				receipt = result
			end
			panel.render()
		end,
		combat = function(name: string)
			local state = current()
			local token = name
			if state and (name == "attack" or name == "ranged") then
				local rival = target(state)
				if not rival then
					return
				end
				token = (if name == "ranged" then "ranged:" else "melee:") .. rival
			end
			send("brawl-action", { token })
			panel.render()
		end,
	}
	panel = Sheet.mount(ctx, {
		id = "brawl",
		name = "Brawl",
		title = M.text(ctx.locale, "brawl_title"),
		order = 65,
		select = function(extensions: any): any
			local state = extensions.brawl
			if state and state.id ~= matchId then
				matchId, receipt, feedback = state.id, nil, nil
			end
			return { brawl = state }
		end,
		rows = function(view: any): { Sheet.Row }
			local state = view and view.brawl
			local policy = if state then state.policy else (ctx.content and ctx.content.brawlPolicy)
			if not policy then
				return { { text = M.text(ctx.locale, "brawl_unavailable") } }
			end
			local model = if state then M.model(state, actor, now(), receipt) else nil
			return M.rows(ctx.locale, model, policy, act, feedback)
		end,
	})
	return panel
end

return M
