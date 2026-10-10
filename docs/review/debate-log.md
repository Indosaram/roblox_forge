# 적대적 리뷰 판정 로그 (2026-09-28)
리뷰어: st_01a0e6d5(근거), st_01a0e6d6(아키텍처), unspecified-high. 원문 review-evidence.md, review-arch.md. 사실 재확인 review-factcheck.json

| ID | 심각도 | 요지 | 판정 | 반영 |
|---|---|---|---|---|
| E-F1 | critical | 요약의 대형작 추월 과장 | SUSTAINED | §1 문장 정정 |
| E-F2 | critical | 외부 유입 전략과 추천 순위 규칙 모순 | 부분 SUSTAINED | 외부 유입을 표본 확보용으로 한정, KPI를 추천 유입 유저 기준으로 변경. 외부 채널 전면 제거 요구는 기각 |
| E-F3 | critical | Steal a Brainrot 저작권 등록·소송 | SUSTAINED(위키 원문 확인) | Kaiju Egg Raiders·팀 공성전으로 변경, 리스크 표, 법률 검토 명시 |
| E-F4 | critical | 누적과 최근 1년 혼합 | SUSTAINED | §2를 2-A/2-B로 분리 |
| E-F5 | critical | 규제 지역 유료 무작위 상품 차단 | SUSTAINED(PolicyService 문서 확인) | Robux는 확정 상품만 |
| E-F6 | major | 채점 기준 순환성 | SUSTAINED | 세부 점수 공개, 과포화 감점 |
| E-F7 | major | 후보 간 이중 잣대 | SUSTAINED | 전 후보 재채점 |
| E-F8 | major | 정렬 기준 부재, Ride A Pet 누락 | SUSTAINED | 2-A CCU 순 정렬, Brookhaven 제외 사유 명시 |
| E-F9 | major | Grow a Garden CCU 붕괴 간과 | SUSTAINED | 반면교사 문단 |
| E-F10 | major | 게임패스 0개 해석 오류 | SUSTAINED(위키 확인) | 소모성 상품 중심으로 정정 |
| E-F11 | major | ARPDAU 목표 부재 | SUSTAINED | ARPDAU 2 R$, DevEx 0.0038 공식 문서 |
| E-F12 | major | 유료 자산 도난 리스크 | SUSTAINED | 유료 괴수 계정 귀속 |
| E-F13 | minor | 개발 그룹명 표기 | SUSTAINED | 주석 |
| E-F14 | minor | [W3] 출처 회수 경로 | 부분 SUSTAINED | 문장은 실재, 회수 경로 주석 |
| E-F15 | minor | KPI 규모 불일치 | SUSTAINED | W5-W6 CCU 10,000 |
| A-F1 | critical | 생성 모델 라이선스 | SUSTAINED(원문 3건). TRELLIS는 MIT로 기각 | Cube·Hunyuan3D·AudioCraft 제외 |
| A-F2 | critical | 오디오 업로드 월 100건 | SUSTAINED(공식 문서) | 재사용 우선, 한도 추적 |
| A-F3 | critical | 코드 수정 0줄 비현실 | SUSTAINED | hook 확장 코드 허용, M5 기준 변경 |
| A-F4 | critical | Mantle 유지보수 중단 | SUSTAINED(README) | forge deploy + rbxcloud |
| A-F5 | critical | Rojo·multi_edit 이중 원본 | SUSTAINED | MCP 코드 도구 읽기 전용 |
| A-F6 | major | 정적 경제 그래프 한계 | SUSTAINED | econ.yml 코드 생성 원본, 멀티 액터 시뮬 |
| A-F7 | major | 웹 API 메시 업로드 비권장 | SUSTAINED(Asphalt README) | 3D Importer → .rbxm |
| A-F8 | major | Lune 엔진 API 부재 | SUSTAINED | core/domain·infra 분리 |
| A-F9 | major | 무버전 모노레포 | SUSTAINED | semver + lockfile |
| A-F10 | major | 모더레이션 지연 | SUSTAINED | PendingModeration 게이트 |
| A-F11 | major | Luau Execution 한도 | SUSTAINED(공식 문서) | CI 60초 스모크 + 로컬 MCP QA |
| A-F12 | major | Blender MCP 임의 코드 실행 | SUSTAINED | 헤드리스 스크립트 |
| A-F13 | major | anticheat 부재 | SUSTAINED | core/anticheat |
| A-F14 | minor | 사전 구축 일정 비현실 | SUSTAINED | extract-as-you-build |
| A-F15 | minor | 광고 URL 검증 부정확 | 부분 SUSTAINED | markdown 경로로 교체 |

집계: 30건 중 SUSTAINED 26, 부분 SUSTAINED 4, 완전 기각 0.
