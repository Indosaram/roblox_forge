# 로방고 섬: 사용자 결정·행동 목록 (2026-10-16)

원본은 로컬 연구 세션 폴더(`.omo/ulw-research/…/preprod/user-actions.md`, gitignore)에 있으며, 이 사본이 저장소 기준본입니다.

에이전트가 할 수 있는 착수 전 작업은 모두 끝났습니다(근거: `ADR-preprod.md`). 아래 항목은 사용자 승인이나 계정, 비용, 외부 기관이 필요해서 에이전트가 대신할 수 없습니다.

## 지금 결정하면 M0를 바로 시작할 수 있는 것
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
| U9 | KR 실측 | 스테이징에서 KR 계정으로 PolicyService 값을 기록합니다. H4 실측(에이전트가 로그 코드를 만들고, 사용자가 접속) | 무료 | ADR-07 |

## 선택
| # | 항목 | 내용 |
|---|---|---|
| U10 | 넥슨 라이선스 문의 | LICENSE 트랙을 원할 때만 필요합니다. 기본은 ORIGINAL입니다 |
| U11 | 서버 정원 상향 | M6 부하 측정 뒤에 다시 판단합니다(ADR-04) |

## 구현 후 갱신 (통합 브랜치, 2026-10-16)
| # | 항목 | 내용 | 비용 | 근거 |
|---|---|---|---|---|
| U12 | main 반영 승인 | 통합 브랜치를 main 에 머지할지 결정합니다(에이전트는 브랜치 push 까지만 했습니다). core·genre 변경이 포함돼 사람 머지가 필요합니다 | 무료 | AGENTS.md layer rules |
| U13 | Studio QA 실행 승인 | wildlife-spatial·full-coop-rejoin·tutorial(QA-CORE-01) 같은 Studio 시나리오, 실제 TeleportService 왕복(QA-TP-01의 2층), 실제 MemoryStore 부하(QA-SPIKE-01의 2층)는 Studio·라이브 서버가 필요해 실행하지 않았습니다 | 무료 | 계획 §12 |
| U14 | 스테이징 배포 | forge deploy 로 스테이징 플레이스에 올리려면 플레이스 ID·API 키(Open Cloud)가 필요합니다 | 무료 | deploy.yml |
| U15 | Robux 상품 등록 | catalog lint 를 통과한 상품 목록(econ.yml)을 실제 Game Pass·Developer Product 로 만들고 ID를 채웁니다. 가격 변경은 사람 승인 사항입니다 | 무료(등록) | AGENTS.md, QA-BM-01 |
| U16 | 오디오·3D 애셋 제작 확정 | 생성 모델 라이선스 규칙(TRELLIS 허용, AudioCraft 등 금지) 안에서 최종 애셋을 만들고 업로드합니다 | 유료 가능 | AGENTS.md |
| U17 | 출처 지문 갱신 | 원작 참고 자료 지문(cli/forge/provenance/reference-ip)은 2026-10-16 시점 공개 문서 기준입니다. 공개 자료가 바뀌면 재생성 여부를 정합니다 | 무료 | A3 provenance |
| U18 | 원작 제목 히스토리 정리 | 통합 브랜치 초기 커밋 3개(d2565da, 9556e85, 1f4002a)의 메시지·파일에 원작 제목이 남아 있습니다. 현재 트리는 금칙어 0건이지만, 공개 저장소로 push 하기 전에 히스토리 재작성(squash 또는 filter-repo)을 할지 결정합니다. 재작성은 force-push 이 필요해 에이전트가 하지 않았습니다 | 무료 | QA-NAME-01 |

결정안: 착수에 필요한 사용자 결정은 모두 끝났고, 나머지는 M7 출시 준비까지 처리하면 된다.
