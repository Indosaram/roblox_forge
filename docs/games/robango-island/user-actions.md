# 로방고 섬: 사용자 결정·행동 목록 (2026-10-21)

원본은 로컬 연구 세션 폴더(`.omo/ulw-research/…/preprod/user-actions.md`, gitignore)에 있으며, 이 사본이 저장소 기준본입니다.

아래 목록은 이전 단일 섬 프로토타입의 사용자 결정·검증 이력입니다. 에이전트 작업이 모두 끝났다는 주장은 철회합니다. 새 후기 온라인 재현 설계의 구현과 검증은 별도이며, 현재 범위는 `fidelity-matrix.md`, 증거 한계는 `qa-evidence.md`의 Readiness correction을 따릅니다. 이력의 완료 표시는 당시 기록된 동작만 뜻하며 새 콘텐츠의 출시 준비 완료를 뜻하지 않습니다.

## 현재 운영 상태와 다음 행동 (2026-10-21)

스테이징 대상은 Universe `10771918494`, Place `95467272687768`입니다. 이 문서의 예전 배포 버전과 모바일 수치는 당시 콘텐츠의 이력이며, 현재 `d1f13db` 또는 진행 중인 P7 변경의 배포·합격 증거가 아닙니다. `690ac33` 이후 P1~P6에서 개인섬·군도·재료/성장·전투·저널·부족·난투·합주·서버 간 시장의 구현과 네이티브 검증이 추가되었습니다. 기능별 실제 입증 범위는 [qa-evidence.md](qa-evidence.md)의 2026-10-21 표를 따릅니다.

현재 계정 moderation warning이 외부 작업의 차단 사유입니다. 아이콘 **253개가 아직 업로드되지 않았고**, 오디오 **55개는 moderation 대기**입니다. 숫자는 이번 복구 작업의 보고 상태이며, 승인 완료나 Roblox에서 사용 가능하다는 뜻이 아닙니다. P7 콘솔에는 `User is moderated`와 asset HTTP 403도 남아 있습니다. 경고 해제·소유권/체험 권한·실제 승인 상태를 사용자가 확인한 뒤에만 승인된 업로드를 재개합니다. 로컬 아이콘 위험 도형 교체 및 검토는 `.omo/evidence/robango-recovery/p6/icon-screen.md`에 있으며 Roblox의 승인 판정을 대체하지 않습니다.

### 로컬 설정 위치와 키 권한

저장소 루트의 gitignore 파일 `.env.local`에 값을 넣습니다. 아래는 **변수 이름만** 나열합니다. 키 값을 문서·Git·로그에 복사하지 않습니다. `.env.example`가 이름의 기준이고 `games/robango-island/deploy.yml`이 배포 대상 변수를 참조합니다.

| 용도 | `.env.local` 변수 이름 |
|---|---|
| 스테이징 배포 대상 | `FORGE_STAGING_UNIVERSE_ID`, `FORGE_STAGING_PLACE_ID` |
| 스테이징 Open Cloud 키와 대상 바인딩 | `ROBLOX_STAGING_API_KEY`, `ROBLOX_STAGING_UNIVERSE_ID`, `ROBLOX_STAGING_PLACE_ID` |
| 프로덕션 배포 대상 | `FORGE_PRODUCTION_UNIVERSE_ID`, `FORGE_PRODUCTION_PLACE_ID` |
| 프로덕션 Open Cloud 키와 대상 바인딩 | `ROBLOX_PRODUCTION_API_KEY`, `ROBLOX_PRODUCTION_UNIVERSE_ID`, `ROBLOX_PRODUCTION_PLACE_ID` |
| 애셋 업로드·조회 | `ROBLOX_API_KEY`; 소유자는 `FORGE_ROBLOX_CREATOR_USER_ID` 또는 `FORGE_ROBLOX_CREATOR_GROUP_ID` 중 하나 |
| 실제 소유자/스테이징 QA | `FORGE_OWNER_USER_ID`, `FORGE_STAGING_OWNER_USER_ID`, `FORGE_QA_ACTOR_IDS` |
| 승인된 프로덕션 배포 게이트 | `FORGE_ALLOW_PRODUCTION` |

각 환경의 FORGE 대상과 ROBLOX 대상 바인딩은 같은 Universe/Place여야 합니다. 예전 U21의 `FORGE_PROD_*`/`ROBLOX_PROD_*` 표기는 현재 계약이 아닙니다. 배포용 키에는 해당 Universe의 **`universe-places` write** 권한이 필요합니다. 업로드용 키에는 **asset read/write**와 Decal의 이미지 콘텐츠 ID 해석을 위한 **`legacy-asset:manage`** 권한이 필요합니다. 환경별 키를 대상 Universe에 제한하고, 생성 애셋 소유자와 업로드 키의 권한을 맞춥니다.

Game Pass / Developer Product의 논리 키→실제 ID 매핑은 `games/robango-island/game.yml`의 monetization 설정과 `games/robango-island/src/shared/MonetizationCatalog.luau`에 있습니다. 현재 스테이징 등록 이력은 U15에 보존합니다. 프로덕션 Universe를 별도로 만들면 그 Universe에 등록한 상품 ID를 이 두 위치에 맞추고 검증해야 합니다. 등록·프롬프트 표출·실제 결제 정산·혜택 적용은 서로 다른 증거입니다.

### 배포 명령과 남은 검증

모든 명령은 저장소 루트에서 실행합니다. `forge`는 `C:/Users/sook/.rokit/bin/lune.exe run cli/forge`입니다. 일반 CLI는 `.env.local`을 자동으로 읽는다고 가정하지 말고 해당 변수를 프로세스 환경에 주입합니다(`cli/forge/publish-staging.sh`만 자동 source 계약이 있습니다).

```text
forge deploy --env staging --pack robango-island --development
forge deploy --env production --pack robango-island
```

두 번째 명령은 사용자 승인·human-merged PR·프로덕션 대상/키·`FORGE_ALLOW_PRODUCTION` 게이트와 release quality 승인이 모두 갖춰진 후에만 실행합니다. `--development`는 스테이징 전용이며 프로덕션 우회 옵션이 아닙니다. 현재 `starter` 등급과 moderation 차단을 출시 승인으로 바꾸지 않습니다. `deploy.yml`의 역할별 place ID가 0인 상태는 실제 다중 Place 여행 배치 완료가 아닙니다.

새 콘텐츠의 실제 개인섬/군도 Teleport 왕복, 서로 다른 실제 계정·JobId의 시장 정산, 다인원 난투/합주, 휴대폰 조작과 성능은 아직 합격으로 기록하지 않습니다. QA-PERF-01 2층 준비 스크립트와 실행법은 `cli/forge/qa/robango-performance.luau`, `cli/forge/qa/robango-performance.md`입니다. 이번 문서 작업에서는 실행하지 않았습니다. 최신 Studio 결과는 별도 캡처 작업의 revision/build 증거가 있어야 갱신합니다.

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
| U15 | Robux 상품 등록 | 완료(2026-10-19, 스테이징): `Robango Staging` Universe(`10771918494`)에 Game Pass 2종(`routeGuildPatron` `2040232413`, `wideWarehouse` `2037904759`), Developer Product 1종(`skinRidgeStriderGold` `3720013569`), Experience Subscription 1종(`routeGuildMonthly` `EXP-4461467833720767028`)을 원가 그대로 등록·활성화하고 `game.yml`과 `MonetizationCatalog.luau`에 반영했습니다. 프로덕션 Universe를 따로 만들 경우 그 Universe의 ID로 교체해야 합니다 | 무료(등록) | AGENTS.md, QA-BM-01 |
| U16 | 오디오·3D 애셋 제작 확정 | 이전 프로토타입의 3D 월드·공룡 리그 및 스토어 이미지 제작·적용 이력은 qa-evidence.md 주 8에 보존합니다(2026-10-20). 새 설계의 24종 실루엣·리그·동작, 지역·시설, 악기·합주 오디오를 모두 제작·검증했다는 뜻이 아닙니다 | 새 설계 미검증 | AGENTS.md, qa-evidence.md 주 8 |
| U17 | 출처 지문 갱신 | 원작 참고 자료 지문(cli/forge/provenance/reference-ip)은 2026-10-16 시점 공개 문서 기준입니다. 공개 자료가 바뀌면 재생성 여부를 정합니다 | 무료 | A3 provenance |
| U18 | 원작 제목 히스토리 정리 | 통합 브랜치 초기 커밋 3개(d2565da, 9556e85, 1f4002a)의 메시지·파일에 원작 제목이 남아 있습니다. 현재 트리는 금칙어 0건이지만, 이 커밋들은 이미 공개 원격의 `durango/integration`에 올라가 있고, main fast-forward 로 main 히스토리에도 포함됩니다. 지우려면 히스토리 재작성(squash 또는 filter-repo) 후 main·integration 둘 다 force-push 해야 하며, 이미 받아 간 사본은 회수할 수 없습니다. force-push 라 에이전트는 하지 않았습니다 | 무료 | QA-NAME-01 |
| U19 | 저사양 실기기 성능 확인(QA-PERF-01 2층) | 이전 콘텐츠 실측 이력(2026-10-18~20): Studio 첫 상호작용 2.86초·월드 생성 0.24초·최대 메모리 2,639MB, 안드로이드 `SM-N981N`의 PSS 704.0MB·프레임 p50 12ms/p90 23ms/p95 36ms입니다(상세는 주 3·8). 새 콘텐츠의 실기기 성능·조작 검증은 아직 완료되지 않았습니다 | 무료 | qa-evidence.md 주 3·8 |
| U20 | 스테이징 QA 2층 확인 | 이전 콘텐츠의 클라우드 저장소 검사·안드로이드 접속·한국 계정 PolicyService·네이티브 결제 프롬프트·일부 플레이 및 재접속 기록은 주 8에 보존합니다(2026-10-19~20). 새 설계의 군도 여행·개인섬 왕복·실제 두 계정 거래(서버 간 정산 포함)·새 콘텐츠 실기기 검증은 미확인입니다. 64인 MemoryStore 부하만 남았다는 주장은 철회하며, 전체 검증 완료로 해석하지 않습니다 | 무료 | qa-evidence.md Readiness correction, 주 8 |
| U21 | 배포 대상·키 입력 | 완료 이력(2026-10-19, 스테이징). 현재 변수 이름·환경별 대상 바인딩·필수 키 권한은 위 로컬 설정 표를 따릅니다. 프로덕션은 `FORGE_PRODUCTION_UNIVERSE_ID`, `FORGE_PRODUCTION_PLACE_ID`, `ROBLOX_PRODUCTION_API_KEY` 및 대응 `ROBLOX_PRODUCTION_UNIVERSE_ID`, `ROBLOX_PRODUCTION_PLACE_ID`가 필요합니다 | 무료 | .env.example |
| U22 | Roblox Studio 설치·실행 | 완료(2026-10-18~19): Windows Studio에서 데스크톱·모바일 첫 플레이 캡처, 전체 흐름 플레이 점검(주 6), Studio 시나리오 3종(주 7)을 실행했습니다. 다시 돌릴 때만 Studio 실행 승인이 필요합니다 | 무료 | docs/release/studio-qa.md |
| U23 | 품질 등급 승격 | `quality.yml` 등급이 starter입니다. release-candidate로 올리려면 실제 첫 플레이 캡처(데스크톱·모바일), 독립 레퍼런스, 평가자(FORGE_QUALITY_EVALUATOR) 승인 영수증이 필요합니다. 에이전트가 스스로 승인할 수 없습니다 | 무료 | forge quality --help |

현재 판단: 기존 결정·배포 이력은 보존하되, 새 설계의 구현과 실제 플레이 검증이 남아 있습니다. 출시 준비 완료나 완전한 원작 재현으로 보고하지 않습니다.
