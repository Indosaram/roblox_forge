# Ultrawork Notepad — Roblox Top10 기반 바이럴 게임 구현계획
Started: 2026-09-28T06:25:34.576Z
Tier: LIGHT (문서 산출물, 코드 변경 없음)
Skills: mass-ulw/ulw-research(요청된 워크플로), bun-1-4(eval), memory playbook(muse 동시성 2-3, 슬림 프롬프트)
## Plan
1. 검색 레인 3개(mimo 고정, task subagent_type=librarian + model override): A Top10 1년 인기, B 메타 도구, C 바이럴·수익화
2. 리드: Roblox 공식 API(games/explore)로 CCU·visits 실측 교차검증
3. 아이디어 ≤5 → 점수 게이트 → 채택만 계획화
4. ROBLOX_VIRAL_GAME_PLAN.md 작성, grep 검증
## Findings
- Roblox games API 200 OK (Blox Fruits universe 994732206)
- omo.json에 research-* 카테고리 없음 → subagent_type+model 오버라이드 사용
- 2026-09-28T06:26:38.273Z roblox-api-measured.json 저장: 누적 방문 Top = Steal a Brainrot 73.69B, Blox Fruits 64.71B, Adopt Me 44.87B, Grow a Garden 35.94B, MM2 30.88B, 99 Nights 29.76B, RIVALS 18.41B, DTI 11.07B, Dead Rails 6.58B, Steal An Egg 5.78B(2026-07-25 생성, 현재 CCU 1.46M)
- Brookhaven universe 1686885941 → games API가 TITLE UNAVAILABLE 반환(레인 A로 확인)
## Now
레인 A/B/C(mimo) 결과 대기
- 2026-09-28T06:32:20.821Z 1차 레인 3개(st_01a0e6b0/b1/b2)는 bash 20회 이상 반복, 텍스트 0 → 취소. 원자적 레인(bash ≤3회, URL 지정)으로 교체. 모델 mimo 유지.
- 위키 직접 fetch(검색 아님): Steal a Brainrot 최고 CCU 25.4M(2025-10), Grow a Garden 22.3M(2025-08-23), 플랫폼 47.4M(2025-08-23). https://en.wikipedia.org/wiki/Steal_a_Brainrot https://en.wikipedia.org/wiki/Grow_a_Garden
- 2026-09-28T06:36:57.651Z 감사 PASS: Top10 10행/URL 10/방문수 10, 아이디어 5개(채택 2), 도구 22행, 주차 8행, mimo 기록, 자리표시자 0. 레인 전부 terminal.
  st_01a0e6b0 [cancelled] model muse/mimo-v2.6-flash-free | st_01a0e6b1 [cancelled] model muse/mimo-v2.6-flash-free | st_01a0e6b2 [cancelled] model muse/mimo-v2.6-flash-free | st_01a0e6b6 [completed] model muse/mimo-v2.6-flash-free | st_01a0e6b7 [cancelled] model muse/mimo-v2.6-flash-free | st_01a0e6b8 [completed] model muse/mimo-v2.6-flash-free
