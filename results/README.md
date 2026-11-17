# 결과

`scripts/run-round.ps1` 이 라운드마다 k6 로그를 `yyyyMMdd-HHmm-users<N>.txt` 로 여기에 저장한다. 라운드가 끝나면 아래 표를 채운다.

| 날짜 | 가상 고객 | 순번 조회 p95 (k6 `queue_me`) | 최대 초당 요청 (Grafana) | order 5xx | `queue_errors` | `queue_not_in_queue` | `queue_ordered` / 한도 | RDS CPU 최대 | 판정 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| | 1,000 | | | | | | | | |
| | 3,000 | | | | | | | | |
| | 5,000 | | | | | | | | |

판정 기준: 순번 조회 p95 1초 미만, `queue_not_in_queue` 0, `queue_ordered`가 한도를 넘지 않음. 셋 다 지키면 "버팀".
