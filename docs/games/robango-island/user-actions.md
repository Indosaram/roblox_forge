# 로방고 섬: 사용자 결정·행동 목록 (2026-10-26)

원본은 로컬 연구 세션 폴더(`.omo/ulw-research/…/preprod/user-actions.md`, gitignore)에 있으며, 이 사본이 저장소 기준본입니다.

아래 목록은 이전 단일 섬 프로토타입의 사용자 결정·검증 이력입니다. 에이전트 작업이 모두 끝났다는 주장은 철회합니다. 새 후기 온라인 재현 설계의 구현과 검증은 별도이며, 현재 범위는 `fidelity-matrix.md`, 증거 한계는 `qa-evidence.md`의 Readiness correction을 따릅니다. 이력의 완료 표시는 당시 기록된 동작만 뜻하며 새 콘텐츠의 출시 준비 완료를 뜻하지 않습니다.

## 2026-10-26 갱신 (`9d673db`)

- 공룡 한국어 표준 표기(브라키오사우루스, 파라사우롤로푸스)로 바꾸면 provenance 검사가 나무위키 참조 8-gram 일치로 막습니다(gate135, 2026-10-26). 사람 검토자 서명이 있는 `provenance/allow.yml` 면제가 있어야 하므로 현재는 기존 표기(브라키오사우러스, 파라사우롤로퍼스)를 유지합니다. 소유자 결정 필요.

상세 기록은 [qa-evidence.md](qa-evidence.md)의 "Current state at `9d673db`" 절을 따릅니다. 경로는 `.omo/evidence/robango-recovery/` 아래의 로컬(gitignore) 파일입니다.

### 에이전트가 처리한 것

- **스테이징 재게시.** `9d673db`를 12개 역할 Place 모두에 게시했습니다. 모두 HTTP 200이고, 온보딩은 v20, 나머지 11개는 v6입니다. Universe는 `PRIVATE` 그대로입니다(`p127/deploy-9d673db.log`). 실서버 플레이 기록은 아직 없습니다.
- **스토어 이미지.** 아이콘 1장과 제목 썸네일 3장(라이더, 제작, 탐험)을 스테이징 Universe `10771918494`에 올렸습니다. 업로드는 모두 HTTP 200이고(`p127/store-upload.txt`), `assets/store/store.yml`(`4f9f889`)이 `staging-uploaded`로 기록합니다. 커밋은 4장 모두 승인으로 기록하지만, 업로드 로그 자체에는 HTTP 200 응답만 있습니다. 프로덕션 업로드는 Universe가 없어 하지 않았습니다.
- **게이트.** `forge gate --pack robango-island`가 `9d673db`에서 PASS했습니다(47개 작업, 실패 0, 282.2초, `p7/gate134.json`). `0172441`(p128)이 `journal-eight-chapters`를 콜드 557초에서 약 64초로 줄였습니다(재생 해시 동일).
- **Studio 재확인**(Studio MCP 실제 입력, PC 1280x720과 휴대폰 360x640 에뮬레이션):
  - `p124/recheck.md`(`827248d`): 5/5 PASS.
  - `p127/recheck.md`(`9979d15`): 방문 이동문 결과 문구 표시, 붕대의 안내(g20 「구조 준비」) 잠금과 g20 오픈 후 제작, 개인섬 부두 확장(4.6 studs에서 승인, 29.5 studs에서 거절) PASS. 휴대폰에서 연습·악기 행 잘림(D1) FAIL.
  - `p130/recheck.md`(`9d673db`): D1 수정 확인(드럼·바이올린 행이 글자에 맞게 늘어남, 1.2배 글자 포함), 게임 스크립트 오류 0.

### 아직 남은 것

- **실기기 휴대폰.** 페어링해 둔 `SM-N981N`이 2026-10-26 확인에서 닿지 않았습니다(adb 장치 없음, ping 응답 없음). 이 확인의 증거 파일은 없습니다. 휴대폰에서 무선 디버깅을 다시 켜 주셔야 실기기 QA를 할 수 있습니다.
- **두 계정 검증.** 거래, 캠프 방문과 대여 반납, 실서버 Place 간 Teleport 왕복은 계정이 하나뿐이라 실행하지 않았습니다.
- **부족 찾기(`ClanStore.browse`, p117).** core 변경(`core/infra/data/ClanStore`)이라 소유자 승인 전에는 커밋하지 않습니다(`p117/report.md`).
- **프로덕션 Universe.** 2026-10-26에 비공개로 만들었습니다: universeId `10773197163`, 시작 placeId `132148614756932`, 역할 place 11개(`home` `72212512236397`, `harbor` `106492640494387`, `archipelago` `140344556126083`, `explore10` `136377785089074`, `explore20` `84161370006436`, `frontier30` `91678651236107`, `frontier40` `110823268413113`, `frontier50` `126820566018758`, `frontier60` `98908763364393`, `brawl` `108306223612176`, `team-outpost` `91781720364859`). 이 Universe에만 쓰기 권한이 있는 배포 키 `robango-production-deploy`(universe-places:write, luau-execution-session:write)를 만들어 ID와 함께 `.env.local`에 넣었습니다(증거 `p133/create-places.txt`). 스토어 아이콘과 제목 썸네일 3장도 올렸습니다(HTTP 200, `p133/store-upload.txt`). Roblox 미디어 목록은 썸네일 3장을 승인으로 표시하고, 체험은 `Private`입니다(`p133/store-media-check.txt`). 빌드는 아직 게시하지 않았습니다.

## 현재 운영 상태와 다음 행동 (2026-10-25, `204bda9`)

기능별 상태와 근거는 [fidelity-matrix.md](fidelity-matrix.md)의 검증 열, 상세 기록은 [qa-evidence.md](qa-evidence.md)의 "Current state at `204bda9`" 절을 따릅니다. 아래 `pNN` 경로는 `.omo/evidence/robango-recovery/` 아래의 로컬(gitignore) 파일입니다.

### 에이전트가 이미 처리한 것

- **Roblox 웹 단계는 에이전트가 소유자의 로그인된 Aside 브라우저 세션으로 처리합니다.** 로그인 정보를 입력하지 않습니다. moderation 경고(애셋 `105225552511668`, 2026-10-21 검토) 확인을 2026-10-25에 완료했습니다(`p106/not-approved.txt`).
- **역할별 Place 생성과 스테이징 배포 완료(2026-10-25, `p107/deploy.md`).** 같은 Aside 세션으로 Place 11개를 만들고 `a0d674c` 빌드를 12개 Place 모두에 게시했습니다(모두 HTTP 200, Open Cloud로 재확인). Universe는 `PRIVATE` 그대로입니다. 이후 같은 명령으로 `71566f8`(온보딩 v17), `9dc99f7`(온보딩 v18, 나머지 v4)을 다시 게시했습니다(`p112`, `p115` 배포 로그).
- **아이콘·오디오 업로드 재개(`9691bfd`, `71566f8`, `p108/screen.md`).** 저위험 배치 01~10을 배치마다 Approved 확인 후 올렸고, 대기 중이던 오디오 15개도 Approved입니다. `204bda9`의 manifest는 Approved 526, NotUploaded 111(검토 등급 아이콘 86, 보류 2, 아이콘 계획 밖 오디오 23), 대기 0입니다.
- **Studio 로그인과 실행은 에이전트가 처리합니다.** Studio QA는 Studio MCP 실제 입력으로 진행합니다(최근: `p112/recheck.md`, `p115/recheck.md`). AGENTS.md 규칙대로 Studio 실행 전에는 사용자에게 묻습니다.

### 소유자만 할 수 있는 행동

1. **두 번째 Roblox 계정.** 계정이 하나뿐이라 두 계정 간 거래(서로 다른 JobId의 시장 정산 포함), 캠프 방문·장비 대여 반납, 부족 가입 신청 승인, 파티 항로 공유, 난투·합주·공성전, 실서버 Place 간 Teleport 왕복을 검증하지 못했습니다(`p115/recheck.md` 4~6행 NOT RUN). 두 번째 계정을 만들어 주거나 테스트에 쓸 계정을 지정해 주세요. 에이전트는 로그인 정보를 입력하지 않으므로 그 계정의 로그인도 소유자가 합니다.
2. **휴대폰 무선 디버깅 연결.** 실기기 기록은 2026-10-20 이전 콘텐츠의 안드로이드 1회뿐이고, 이후 360x640 결과는 모두 Studio 에뮬레이션입니다. 휴대폰에서 무선 디버깅을 켜고 페어링해 주어야 실기기 QA를 다시 할 수 있습니다.
3. **Robux 지출 승인.** 실제 결제 영수증 정산과 혜택 적용 확인, 저연령 노출 요건(U7) 같은 유료 단계는 소유자 승인 전에는 실행하지 않습니다. 가격·확률 변경도 소유자 승인이 필요합니다.
4. **프로덕션 게시(품질 게이트 대기).** `forge deploy --env production`은 `quality.yml`의 tier가 `starter`라서 `QUALITY_GATE_FAILED`로 거부합니다(dry-run 확인, 2026-10-26). 게시하려면 `release-candidate` 평가 영수증이 필요하고, 영수증에는 두 번째 실제 계정과 소유자 평가자 서명이 들어갑니다. 소유자는 게이트를 기다리기로 했습니다(2026-10-26). 영수증이 생기면 `FORGE_ALLOW_PRODUCTION=1`로 게시하고, 그 전에 프로덕션 Universe에 상품 4종을 등록하고 ID를 `.env.local`의 `FORGE_PRODUCTION_PRODUCT_*` 4개에 넣으세요. `forge deploy`가 환경별 상품 ID를 빌드에 넣습니다(`6e49e68`). 비워 둔 상품은 상점에 보이지만 결제 창은 열지 않으므로, 스테이징 상품이 프로덕션에서 팔리는 일은 없습니다.

### 스테이징 Place와 배포 명령

Universe `10771918494`(`PRIVATE`). 시작 Place는 `FORGE_STAGING_PLACE_ID`, 나머지 역할은 `games/robango-island/deploy.yml`이 `FORGE_STAGING_ROLE_*` 환경 변수로 참조합니다(`cc950b5`). ID는 `.env.local`에만 둡니다.

| 역할 | Place ID | 환경 변수 |
|---|---|---|
| onboarding (시작) | 95467272687768 | `FORGE_STAGING_PLACE_ID` |
| home | 138037124358403 | `FORGE_STAGING_ROLE_HOME` |
| harbor | 74762124664475 | `FORGE_STAGING_ROLE_HARBOR` |
| archipelago | 71669922813678 | `FORGE_STAGING_ROLE_ARCHIPELAGO` |
| explore10 | 113022535464737 | `FORGE_STAGING_ROLE_EXPLORE_TEN` |
| explore20 | 124582682750666 | `FORGE_STAGING_ROLE_EXPLORE_TWENTY` |
| frontier30 | 97353598156206 | `FORGE_STAGING_ROLE_FRONTIER_THIRTY` |
| frontier40 | 101898062384284 | `FORGE_STAGING_ROLE_FRONTIER_FORTY` |
| frontier50 | 84995036714900 | `FORGE_STAGING_ROLE_FRONTIER_FIFTY` |
| frontier60 | 114521850689528 | `FORGE_STAGING_ROLE_FRONTIER_SIXTY` |
| brawl | 85368204973944 | `FORGE_STAGING_ROLE_BRAWL` |
| team-outpost | 122380491449815 | `FORGE_STAGING_ROLE_TEAM_OUTPOST` |

저장소 루트에서 `.env.local`의 변수를 프로세스 환경에 넣고, `bun`이 PATH에 있어야 합니다(게시 전송에 필요). dry-run 마지막 줄이 `12 role places publishable, 0 missing, 0 errors (deploy --all-roles ready)`일 때만 게시합니다.

```text
lune run cli/forge deploy --env staging --pack robango-island --development --dry-run
lune run cli/forge deploy --env staging --pack robango-island --development --all-roles
```

`--all-roles`는 한 번 빌드한 같은 아티팩트를 시작 Place를 마지막으로 12개 Place에 1회씩 게시하고, 누락·중복 ID가 있으면 빌드와 네트워크 전에 거부하며, 실패하면 그 자리에서 멈춥니다. `--development`는 스테이징 전용입니다.

### 로컬 설정 위치와 키 권한

저장소 루트의 gitignore 파일 `.env.local`에 값을 넣습니다. 아래는 **변수 이름만** 나열합니다. 키 값을 문서·Git·로그에 복사하지 않습니다. `.env.example`가 이름의 기준입니다.

| 용도 | `.env.local` 변수 이름 |
|---|---|
| 스테이징 배포 대상 | `FORGE_STAGING_UNIVERSE_ID`, `FORGE_STAGING_PLACE_ID`, `FORGE_STAGING_ROLE_*` 11개(위 표) |
| 스테이징 Open Cloud 키와 대상 바인딩 | `ROBLOX_STAGING_API_KEY`, `ROBLOX_STAGING_UNIVERSE_ID`, `ROBLOX_STAGING_PLACE_ID` |
| 프로덕션 배포 대상 | `FORGE_PRODUCTION_UNIVERSE_ID`, `FORGE_PRODUCTION_PLACE_ID` |
| 프로덕션 Open Cloud 키와 대상 바인딩 | `ROBLOX_PRODUCTION_API_KEY`, `ROBLOX_PRODUCTION_UNIVERSE_ID`, `ROBLOX_PRODUCTION_PLACE_ID` |
| 애셋 업로드·조회 | `ROBLOX_API_KEY`; 소유자는 `FORGE_ROBLOX_CREATOR_USER_ID` 또는 `FORGE_ROBLOX_CREATOR_GROUP_ID` 중 하나 |
| 실제 소유자/스테이징 QA | `FORGE_OWNER_USER_ID`, `FORGE_STAGING_OWNER_USER_ID`, `FORGE_QA_ACTOR_IDS` |
| 승인된 프로덕션 배포 게이트 | `FORGE_ALLOW_PRODUCTION` |

각 환경의 FORGE 대상과 ROBLOX 대상 바인딩은 같은 Universe/Place여야 합니다. 배포용 키에는 해당 Universe의 **`universe-places` write** 권한이, 업로드용 키에는 **asset read/write**와 **`legacy-asset:manage`** 권한이 필요합니다. Game Pass / Developer Product / Subscription의 환경별 ID는 `games/robango-island/deploy.yml`의 `environments.<env>.monetization`에 있습니다. 스테이징은 값이 직접 적혀 있고, 프로덕션은 `.env.local`의 `FORGE_PRODUCTION_PRODUCT_ROUTE_GUILD_PATRON`, `_WIDE_WAREHOUSE`, `_SKIN_RIDGE_STRIDER_GOLD`, `_ROUTE_GUILD_MONTHLY`를 읽습니다. 배포할 때 이 ID가 `ServerStorage.ForgeMonetizationIds`로 빌드에 들어가고, 게시 직전에 다시 확인합니다. `game.yml`과 `MonetizationCatalog.luau`의 ID는 Studio에서 쓰는 스테이징 기본값입니다. 등록·프롬프트 표출·실제 결제 정산·혜택 적용은 서로 다른 증거입니다.

### 남은 에이전트 작업(소유자 대기 없음)

- 최신 main을 스테이징에 다시 게시하고, 한 계정으로 가능한 실서버 확인(부두에서 다른 Place로 이동 등)을 기록합니다. 아직 실서버 플레이 기록은 없습니다. (2026-10-26: `9d673db` 게시 완료, 실서버 플레이는 아직 없음)
- 검토 등급 아이콘 배치 11~19는 사람이 배치를 본 뒤에만 올립니다(`p85/upload-plan.md`).
- `p115/recheck.md`의 D1(기술 이름 대신 노드 ID), D3·D4(부족 패널 상태·원시 키) 수정.

## 이전 결정·실행 이력

아래 U 항목은 날짜별 이력입니다. 현재 설정·차단 상태는 위 절이 우선합니다.

## 지금 결정하면 M0를 바로 시작할 수 있는 것 (이력)
| # | 항목 | 권고 | 필요한 시점 | 근거 |
|---|---|---|---|---|
| U1 | ~~작업명~~ **완료**: 「로방고 섬 / Robango Island」(2026-10-16) | slug `robango-island` | — | trademark-search.md §8 |
| U2 | Roblox Studio 실행 승인 | wildlife-spatial·full-coop-rejoin 같은 Studio QA를 돌릴 때만 필요합니다 | M1~M2 | AGENTS.md |

## 출시 전까지 필요한 것 (M7 리드타임)
| # | 항목 | 내용 | 비용 | 근거 |
|---|---|---|---|---|
| U3 | 상표 정식 검색·출원 | 변리사에게 USPTO·KIPRIS·EUIPO 9·41류 정식 검색을 맡기고, **원작 상표(등록·출원 2건, legal-review-packet.md §3)와 유사한지 판단을 받습니다.** 원하면 출원합니다 | 유료 | trademark-search.md §5 |
| U4 | 외부 법률 검토 | §3 차별화 표와 "섬 분류·아이템 안정성" 행을 첨부합니다 | 유료 | 계획 §15 |
| U5 | GRAC 등급분류 서면 질의 | 개인 제작 Roblox 체험이 GRAC 등급분류 대상인지 묻습니다(GRAC 1:1 문의 또는 문체부 게임콘텐츠산업과 044-203-3268). 미해결 H7 | 무료 | kr-policy.md H7 |
| U6 | 소유 계정 준비 | 신분증 인증, 2단계 인증, 그룹 소유로 할지 결정 | 무료 | kr-policy.md C29 |
| U7 | 저연령(Kids/Select) 노출 요건 | Roblox Plus/Premium 2개월 유지 또는 환불형 퍼블리시 요금, 그리고 16세 이상 평가 기간(engaged 250명). 일정을 줄이려면 신속 심사 50,000 Robux | 유료 | kr-policy.md C29 |
| U8 | DevEx 준비 | W-8BEN 세금 양식과 DevEx 포털(Tipalti). 실명을 일관되게 써야 합니다 | 무료 | kr-policy.md 추가 |
| U9 | KR 실측 | 완료(2026-10-20): 한국 로케일 계정(`ko-kr`)으로 안드로이드 실기기(`SM-N981N`)에서 스테이징에 접속해 `PolicyService` 통과 후 구독(`EXP-4461467833720767028`, `Route Guild Monthly 99/월`) 및 개발자 상품(`3720013569`, `Ridge Strider Gold Skin 199`) 네이티브 결제 프롬프트 표출을 확인했습니다(qa-evidence.md 주 8) | 무료 | ADR-07 |

## 선택
| # | 항목 | 내용 |
|---|---|---|
| U10 | 넥슨 라이선스 문의 | LICENSE 트랙을 원할 때만 필요합니다. 기본은 ORIGINAL입니다 |
| U11 | 서버 정원 상향 | M6 부하 측정 뒤에 다시 판단합니다(ADR-04) |

## 구현 후 갱신 (통합 브랜치, 2026-10-16)
| # | 항목 | 내용 | 비용 | 근거 |
|---|---|---|---|---|
| U12 | ~~main 반영 승인~~ **완료**: 사용자 승인("모두 가장 좋은 대로", 2026-10-17)에 따라 에이전트가 `durango/integration`을 main 에 fast-forward 했습니다(force 없음). 이후 main 보호 규칙·리뷰 정책은 사용자가 정합니다 | — | AGENTS.md layer rules |
| U13 | 라이브 서버 QA 2층 | Studio 시나리오 wildlife-spatial·full-coop-rejoin·tutorial(QA-CORE-01)은 2026-10-19 Windows Studio에서 통과했습니다(qa-evidence.md 주 7). 실제 TeleportService 왕복(QA-TP-01의 2층)과 실제 MemoryStore 부하(QA-SPIKE-01의 2층)는 라이브 서버가 필요해 아직 실행하지 않았습니다 | 무료 | 계획 §12 |
| U14 | 스테이징 배포 | 완료(2026-10-19): 비공개 체험 `Robango Staging`(universeId `10771918494`, placeId `95467272687768`)을 생성하고 Open Cloud API 키를 `.env.local`(gitignore)에 설정해 `forge deploy --env staging --pack robango-island --development`로 버전 2를 게시·검증했습니다(qa-evidence.md 주 8). 프로덕션 배포만 별도 Universe/Place·승인이 필요합니다 | 무료 | deploy.yml |
| U15 | Robux 상품 등록 | 완료(2026-10-19, 스테이징): `Robango Staging` Universe(`10771918494`)에 Game Pass 2종(`routeGuildPatron` `2040232413`, `wideWarehouse` `2037904759`), Developer Product 1종(`skinRidgeStriderGold` `3720013569`), Experience Subscription 1종(`routeGuildMonthly` `EXP-4461467833720767028`)을 원가 그대로 등록·활성화하고 `game.yml`과 `MonetizationCatalog.luau`에 반영했습니다. 프로덕션(`10773197163`)은 아직 등록 전입니다. 같은 가격으로 등록한 뒤 `.env.local`의 `FORGE_PRODUCTION_PRODUCT_*`를 채우면 되고, 코드 수정은 필요 없습니다 | 무료(등록) | AGENTS.md, QA-BM-01 |
| U16 | 오디오·3D 애셋 제작 확정 | 이전 프로토타입의 3D 월드·공룡 리그 및 스토어 이미지 제작·적용 이력은 qa-evidence.md 주 8에 보존합니다(2026-10-20). 새 설계의 24종 실루엣·리그·동작, 지역·시설, 악기·합주 오디오를 모두 제작·검증했다는 뜻이 아닙니다 | 새 설계 미검증 | AGENTS.md, qa-evidence.md 주 8 |
| U17 | 출처 지문 갱신 | 원작 참고 자료 지문(cli/forge/provenance/reference-ip)은 2026-10-16 시점 공개 문서 기준입니다. 공개 자료가 바뀌면 재생성 여부를 정합니다 | 무료 | A3 provenance |
| U18 | 원작 제목 히스토리 정리 | 통합 브랜치 초기 커밋 3개(d2565da, 9556e85, 1f4002a)의 메시지·파일에 원작 제목이 남아 있습니다. 현재 트리는 금칙어 0건이지만, 이 커밋들은 이미 공개 원격의 `durango/integration`에 올라가 있고, main fast-forward 로 main 히스토리에도 포함됩니다. 지우려면 히스토리 재작성(squash 또는 filter-repo) 후 main·integration 둘 다 force-push 해야 하며, 이미 받아 간 사본은 회수할 수 없습니다. force-push 라 에이전트는 하지 않았습니다 | 무료 | QA-NAME-01 |
| U19 | 저사양 실기기 성능 확인(QA-PERF-01 2층) | 2026-10-21 `9db8e04`의 Studio 360x640·Level01 콜드 Play 3회(각 120초 표본)에서 초기 상호작용 조건이 실패했습니다. ForgeState와 HUD는 준비되지만 가장 가까운 채집 프롬프트가 14.17 studs 거리이고 작동 범위는 8 studs여서, 이동 없이는 상호작용 가능 상태를 관측하지 못했습니다(TTFI 미관측). 이후 `c6dec48`에서 채집 노드를 스폰 옆으로 옮겼고, 2026-10-23 `2e5ca3b` 재측정(`p54/perf.md`, 같은 방법·콜드 Play 3회)에서 TTFI가 3회 모두 관측됐습니다: 중앙값 0.671초(0.629~1.333초), 첫 프롬프트 `fiber-bush-01` 5.46 studs(작동 범위 8). Studio 프로세스 메모리는 중앙값 1,500.0MB, 최대 1,576.6MB입니다(2026-10-21 `9db8e04`: 중앙값 2,355.383MB, 최대 3,257.449MB, 당시 Studio 2개 동시 실행). Studio는 Play 시작 시 프로필을 초기화해 약 10초 뒤 재적용되므로, TTFI는 기본 화면 설정에서 측정된 값입니다. 이는 휴대폰 메모리가 아니며, 런타임 메모리 기준이 정의돼 있지 않아 합격/불합격 판정이 없습니다. 이전 콘텐츠 이력(2026-10-18~20): Studio 첫 상호작용 2.86초·최대 메모리 2,639MB, 안드로이드 `SM-N981N` PSS 704.0MB·프레임 p50 12ms/p90 23ms/p95 36ms. 새 콘텐츠의 저사양 실기기 성능·조작 검증은 미완료입니다 | 무료 | qa-evidence.md 주 3·8, `.omo/evidence/robango-recovery/p13/perf.md` |
| U20 | 스테이징 QA 2층 확인 | 이전 콘텐츠의 클라우드 저장소 검사·안드로이드 접속·한국 계정 PolicyService·네이티브 결제 프롬프트·일부 플레이 및 재접속 기록은 주 8에 보존합니다(2026-10-19~20). 새 설계의 군도 여행·개인섬 왕복·실제 두 계정 거래(서버 간 정산 포함)·새 콘텐츠 실기기 검증은 미확인입니다. 64인 MemoryStore 부하만 남았다는 주장은 철회하며, 전체 검증 완료로 해석하지 않습니다 | 무료 | qa-evidence.md Readiness correction, 주 8 |
| U21 | 배포 대상·키 입력 | 완료 이력(2026-10-19, 스테이징). 현재 변수 이름·환경별 대상 바인딩·필수 키 권한은 위 로컬 설정 표를 따릅니다. 프로덕션은 `FORGE_PRODUCTION_UNIVERSE_ID`, `FORGE_PRODUCTION_PLACE_ID`, `ROBLOX_PRODUCTION_API_KEY` 및 대응 `ROBLOX_PRODUCTION_UNIVERSE_ID`, `ROBLOX_PRODUCTION_PLACE_ID`가 필요합니다 | 무료 | .env.example |
| U22 | Roblox Studio 설치·실행 | 완료(2026-10-18~19): Windows Studio에서 데스크톱·모바일 첫 플레이 캡처, 전체 흐름 플레이 점검(주 6), Studio 시나리오 3종(주 7)을 실행했습니다. 다시 돌릴 때만 Studio 실행 승인이 필요합니다 | 무료 | docs/release/studio-qa.md |
| U23 | 품질 등급 승격 | `quality.yml` 등급이 starter입니다. release-candidate로 올리려면 실제 첫 플레이 캡처(데스크톱·모바일), 독립 레퍼런스, 평가자(FORGE_QUALITY_EVALUATOR) 승인 영수증이 필요합니다. 에이전트가 스스로 승인할 수 없습니다 | 무료 | forge quality --help |

현재 판단: 기존 결정·배포 이력은 보존하되, 새 설계의 구현과 실제 플레이 검증이 남아 있습니다. 출시 준비 완료나 완전한 원작 재현으로 보고하지 않습니다.
