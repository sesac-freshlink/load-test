# 결과

`scripts/run-round.ps1` 이 라운드마다 k6 로그를 `yyyyMMdd-HHmm-users<N>.txt` 로 여기에 저장한다. 라운드가 끝나면 아래 표를 채운다.

| 날짜 | 가상 고객 | 순번 조회 p95 (k6 `queue_me`) | 최대 초당 요청 (Grafana) | order 5xx | `queue_errors` | `queue_not_in_queue` | `queue_ordered` / 한도 | RDS CPU 최대 | 판정 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 2026-11-17 | 1,000 | 15.9ms (최대 173ms) | 360 (order CPU 최대 45%) | 0 | 0 | 0 | 99 / 100 | 8.65% | 버팀 |
| 2026-11-17 | 3,000 | 138ms (최대 5.76s) | 1,150 (order CPU 최대 61%) | 0 (연결 실패 3,643) | 3,643 | **2,674** | 주문 접수 184 (판매 수량 확인 중) | 7.1% | **무너짐: order 파드 OOMKilled** |
| | 5,000 | | | | | | | | |

판정 기준: 순번 조회 p95 1초 미만, `queue_not_in_queue` 0, `queue_ordered`가 한도를 넘지 않음. 셋 다 지키면 "버팀".

### 1,000명 라운드 메모 (2026-11-17)

- order-service CPU는 시작 순간(동시 줄 서기) 45%까지 튀었고, 초당 360건이 이어지는 동안에는 약 22%였다.
- DB 커넥션: 순번 조회는 Redis만 쓴다. order-service의 DB 사용은 초당 최대 약 11회, 한 번 점유 평균 8ms(최대 276ms)였다. 풀 10개 중 평균 동시 사용은 약 0.04개였다(`hikaricp_connections_usage_seconds_count` 약 6,270회 / 20분). 대시보드의 활성 0은 15초 간격 게이지 수집 때문에 생긴 착시다.
- 부하 전에도 초당 4~5회 DB를 썼다(Outbox 폴링, 입장 스케줄러 ShedLock 등 배경 작업으로 추정). 그래서 "주문 99건만 DB를 썼다"가 아니다.
- RDS 연결 60개 = 서비스 파드 6개 × 풀 10개. RDS CPU 최대 8.65%.

### 3,000명 라운드 메모 (2026-11-17 20:20–20:36)

- 20:28:58 order-service 파드가 **OOMKilled**(Exit 137)로 재시작했다. 메모리 상한 768Mi에 working set 750MiB까지 찼다. 힙은 297.5MiB만 썼고, 힙 밖 메모리(약 260MiB)와 네이티브 메모리(약 186MiB)가 커서 넘쳤다. 아래 실측표 참고.
- 재시작 동안(1~2분) k6 요청이 연결 단계에서 실패했다(오류 3,643건, 서버까지 못 가서 Grafana 5xx는 0). 순번 조회가 30초 넘게 끊긴 대기자 2,674명이 입장 스케줄러의 조회 끊김 규칙으로 줄에서 빠졌다.
- 재시작 전 최고치: 초당 1,150건, CPU 61%, 힙 243MiB(30초 간격 수집), 스레드 251개. 처음 몰린 20:20:30에는 일부 요청이 약 30초를 기다렸다(p95가 30초 구간에 걸림).
- inventory-service(초당 17건, p95 113ms)와 RDS(CPU 최대 7.1%, 연결 60 고정), Redis는 끝까지 정상이었다.
- 고칠 점(후보): order-service 메모리 상한을 1Gi로 올리고 `MALLOC_ARENA_MAX=2`를 넣는다(MaxRAMPercentage만 낮추는 건 효과 작음, 힙이 원인이 아니었음). 파드를 2개 이상으로 늘린다(점주 매출 SSE 때문에 지금은 1개, Redis Pub/Sub 필요). 줄 서기 몰림을 줄이려 화면 폴링 간격을 대기 인원에 따라 늘린다.

#### 3,000명 OOMKilled 메모리 실측 (Prometheus, 20:28:30 재시작 직전)

| 항목 | MiB |
| --- | ---: |
| 힙 committed (used 226) | 297.5 |
| 힙 밖 committed: Metaspace 156.3 + 코드 캐시 83.5 + Compressed Class 20.4 | 260.2 |
| direct buffer | 6.0 |
| JVM 지표에 안 잡히는 네이티브 메모리 (스레드 234~251개 스택, GC·JIT 내부, glibc malloc 영역, 연결 3,000개 소켓 버퍼 등) | 약 186 |
| **컨테이너 working set** | **750.1** (최대 751.0, 상한 768) |

- 힙이 꽉 찬 게 아니다. 힙 committed는 MaxRAMPercentage 상한(576)의 절반쯤인 297.5MiB에서 멈췄다.
- 힙 밖(260) + 네이티브(약 186) = 약 450MiB가 768MiB의 60%를 차지했다. 30초 간격 수집 사이에 남은 18MiB를 넘어 OOMKilled.
- 대책 후보: 메모리 상한 1Gi(가장 단순), `MALLOC_ARENA_MAX=2`(glibc 영역 줄이기), 가상 스레드(`spring.threads.virtual.enabled=true`, 스레드 스택 줄이기), 파드 2개. 확정하려면 `-XX:NativeMemoryTracking=summary`로 같은 부하를 다시 준다.
- **대응:** gitops #28(dev order-service 메모리 상한 1Gi, `JAVA_TOOL_OPTIONS=-Xmx400m -XX:+ExitOnOutOfMemoryError -XX:NativeMemoryTracking=summary`)을 머지했다. 재테스트는 11/18 예정이다. 예상 최악 합계는 약 880MiB / 1024MiB다.
