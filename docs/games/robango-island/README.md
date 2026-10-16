# 로방고 섬 (Robango Island) 출시·운영 문서

게임 팩 `robango-island`의 출시 준비(M7)와 라이브 운영(M9) 문서입니다. 팩 코드는 다른 레인에서 만들고 있으며, 이 폴더는 문서만 담습니다. 모든 문서는 초안이고, 외부 제출·결제·배포는 사용자 승인 후 사용자가 직접 합니다.

원자료: `roblox_forge/.omo/plans/durango-roblox-port.md`(계획), `.omo/ulw-research/20261016-023844-durango/preprod/`(ADR-preprod.md, kr-policy.md, trademark-search.md); 사용자 몫 목록은 이 폴더의 user-actions.md.

| 파일 | 내용 | 관련 계획 절 | 사용자 몫 |
| --- | --- | --- | --- |
| [sunset-policy.md](sunset-policy.md) | 서비스 종료 정책: 결제 차단일, 환불 창(Roblox 정책), 본거지섬 보존, 엔딩 이벤트, 체크리스트 | §13, §15 | 보존 방식과 일정 결정 |
| [maturity-questionnaire-draft.md](maturity-questionnaire-draft.md) | Maturity & Compliance 설문 15개 카테고리 답변 초안(목표 Mild). **DRAFT, 사용자가 직접 제출** | §6, §8, §15 | 빌드 확인 후 제출 |
| [legal-review-packet.md](legal-review-packet.md) | 변호사·변리사 검토 패킷: IP 트랙, 차별화 표, 이름 위험, 게임산업법 요약, 질문 22개 | §0, §2, §3, §16 | 검토 의뢰와 비용 승인(U3, U4) |
| [liveops-season1.md](liveops-season1.md) | 시즌 1(M9) 초안: 신규 바이옴, 보스형, 스토리 비트, 4대4 옵트인 공성 암초, 6주 캘린더 템플릿 | §5, §6, §7, §13, §14 | 가격·수치 PR 머지 |
| [kr-launch-checklist.md](kr-launch-checklist.md) | 한국 전용 단계: GRAC 질의문, PolicyService 실측 절차, Kids/Select 요건 일정 | §15, ADR-07, ADR-08 | 질의 발송, KR 계정 접속, 비용 항목 승인(U5~U9) |

## 이름 관련 주의

출시물(타이틀, 지명, 상품명, 로케일)에는 원작 이름을 쓰지 않습니다(계획 D-2, QA-NAME-01). 원작 이름은 이 폴더에서 legal-review-packet.md와 이 README에서만, 위험을 설명하는 맥락으로 씁니다. 작업명 「로방고 섬」은 "DURANGO", "DURANGO WORLD"와 발음이 비슷한 위험이 있으며, 사용자가 이를 알고 골랐고 M7 변리사 검토 대상입니다(trademark-search.md §8).

금칙어 검사(이 폴더):

```sh
grep -rniE "durango|듀랑고|wild lands|야생의 땅|개척|pioneer|워프" docs/games/robango-island
```

허용되는 결과는 legal-review-packet.md와 README.md 안의 줄뿐입니다.
