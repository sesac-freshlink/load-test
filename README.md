# load-test

FreshLink 부하 테스트. 지금은 **선착순 구매 대기열(오픈런)** 한 가지다.
가상 고객 1,000명, 3,000명, 5,000명으로 세 번 돌려서 어디까지 버티는지 찾는다. 3,000명 라운드는 Grafana와 고객 화면을 함께 녹화한다.

| 경로 | 내용 |
| --- | --- |
| `k6/openrun-queue.js` | k6 스크립트. 가상 고객이 줄을 서고 → 2.5초마다 순번을 조회하고 → 입장하면 주문하고(10%는 포기) → 품절이면 끝낸다 |
| `k8s/k6-job.yaml` | dev 클러스터에서 k6를 돌리는 Job |
| `scripts/run-round.ps1` | 라운드 하나를 실행한다(설정 올리기, 전 Job 지우기, Job 실행, 로그를 `results/`에 저장) |
| `results/` | 라운드별 k6 로그와 결과 표 |

걸리는 시간은 약 1시간 30분이다. 준비 30분, 라운드 3번(각 약 7분, 사이에 10분씩 쉰다), 정리 10분.

---

## 0. 먼저 알아 둘 것

**왜 dev인가.** prod에는 11/20 시연 데이터가 있다. 이 테스트는 라운드마다 가짜 주문을 약 100건 만들고(10분 뒤 자동 만료), order-service 파드 1개에 초당 최대 2,000건을 보낸다. dev와 prod는 크기가 같아서(t3.large×2, Valkey t4g.micro, order 파드 1개) 결과가 그대로 통한다.

**가상 고객은 어떻게 만드나.** k6의 VU(가상 사용자) 1개가 고객 1명이다. VU마다 사용자 ID가 다르다(`lt-<RUN_ID>-<번호>`). 그래서 대기열(Redis)에도 진짜로 N명이 따로 선다.

- **로그인은 하지 않는다.** k6를 **클러스터 안 Job**으로 돌려서 order-service를 직접 부르고, gateway가 원래 붙이는 `X-User-Id`, `X-User-Role: CUSTOMER` 헤더를 k6가 대신 붙인다. 실제로 로그인하려면 Cognito 계정이 수천 개 있어야 한다.
- 그래서 **gateway·ALB·CloudFront에는 부하가 가지 않는다.** 실제 사용자 경로에서는 gateway도 같은 노드에서 일하므로, 실제 한계는 이 테스트 결과의 **절반쯤**으로 본다.

**시나리오 (한도 100개 기준).**
1. 10초 안에 N명이 몰린다.
2. 앞 100명이 입장권(5분)을 받는다. 90명은 5~60초 안에 주문하고, 10명은 포기한다.
3. 포기한 입장권이 5분 뒤 사라지면 다음 10명이 입장한다.
4. 다 팔리면 나머지는 "품절"을 받는다.

대부분의 VU가 6~7분 동안 2.5초마다 순번을 묻는다. 초당 요청 수는 약 **0.4 × N**이다(1,000명이면 400, 3,000명이면 1,200, 5,000명이면 2,000).

**예상 (코드를 읽고 계산한 값이라 실측으로 확인한다).** order 파드 1개는 초당 800~1,500건쯤 버틴다고 본다. 그러면 1,000명은 여유 있게 버티고, 3,000명은 경계에 걸리고, 5,000명에서는 응답이 느려지기 시작할 것이다. Valkey와 RDS는 병목이 아니다(DB에는 라운드마다 주문 100건 남짓만 생긴다).

**"버틴다"의 기준.** 셋 다 만족하면 버틴 것이다.
- 순번 조회 p95가 1초 미만이다.
- 줄에서 빠진 사람(`queue_not_in_queue`)이 0이다. 응답이 30초 가까이 걸리면 "조회 끊김"으로 판정돼 줄에서 빠진다.
- 한도를 넘게 팔리지 않는다.

**비용.** 3번째 노드(t3.large)를 2시간 쓰는 비용과 AZ 간 트래픽을 합쳐 0.5달러 안쪽이다.

---

## 1. 준비물 (PC, 한 번만)

1. PowerShell을 연다. 아래 두 명령이 모두 버전을 출력하면 된다.
   ```powershell
   aws --version
   kubectl version --client
   ```
   kubectl이 없으면 `winget install -e --id Kubernetes.kubectl` 를 실행하고 PowerShell을 새로 연다.
2. OBS Studio를 설치한다(녹화용). Windows 게임 바는 창 하나만 녹화해서 Grafana와 고객 화면을 나란히 찍을 수 없다.
   ```powershell
   winget install -e --id OBSProject.OBSStudio
   ```
3. 이 레포를 받는다.
   ```powershell
   cd C:\fresh-link\repos
   git clone https://github.com/sesac-freshlink/load-test.git
   cd load-test
   git pull
   ```

## 2. dev 클러스터 접속 + 노드 3대로 늘리기

dev는 평일 09:00–21:00에만 켜져 있다. 21:00에 노드가 0대가 되므로 **19:00 전에 시작**한다.

1. 클러스터 접속 정보를 받는다.
   ```powershell
   $env:AWS_PROFILE = "freshlink-admin"
   aws eks update-kubeconfig --name freshlink-dev-eks --region ap-northeast-2
   kubectl -n freshlink get pods
   ```
   `order-service-...`, `gateway-...`, `inventory-service-...` 가 모두 `Running`이면 된다.
2. 노드를 3대로 늘린다. k6 파드가 order-service와 CPU를 나눠 쓰지 않게 하려는 것이다. 노드 최대 수가 3으로 잡혀 있다.
   ```powershell
   aws eks update-nodegroup-config --cluster-name freshlink-dev-eks --nodegroup-name freshlink-dev-nodes --scaling-config desiredSize=3 --region ap-northeast-2
   ```
3. 3~5분 뒤 `kubectl get nodes` 를 실행해서 `Ready` 가 3줄이면 된다.

## 3. 선착순 상품 정하기 (점주 화면)

1. dev 계정 비밀번호를 본다.
   ```powershell
   aws secretsmanager get-secret-value --secret-id freshlink-dev-seed-accounts --query SecretString --output text --region ap-northeast-2
   ```
   `owner1@freshlink.test`(프레시 강남점, 점포 1), `sim-customer1@freshlink.test`, `sim-customer2@freshlink.test` 의 비밀번호를 메모한다.
2. https://dev.getfreshlink.com 에 `owner1@freshlink.test`로 로그인 → **매장 재고 → 선착순 탭**으로 간다.
3. **재고가 가장 많은 상품**을 골라 **선착순 켜기, 한도 100**으로 저장한다. 재고가 100보다 적으면 그 재고 수를 한도로 한다.
4. 고객 화면에서 그 상품 상세를 연다. 주소가 `/customer/stores/1/products/<상품ID>` 이니 **상품ID**를 메모한다.

## 4. Grafana 열기

PowerShell 창을 하나 따로 열어 그대로 둔다.

```powershell
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Chrome에서 http://localhost:3000 → Dashboards → FreshLink → **FreshLink 서비스**로 간다. 위쪽에서 **서비스 = order-service**, 시간 범위 **Last 15 minutes**, 새로 고침 **5s**로 맞춘다.
지표는 30초마다 모이기 때문에 그래프가 30~60초 늦게 따라온다.

## 5. 라운드 1: 1,000명 (녹화 없이)

`load-test` 폴더의 PowerShell에서 실행한다. `<상품ID>`는 3장에서 메모한 값으로 바꾼다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-round.ps1 -Users 1000 -ProductId <상품ID>
```

- `running (...), 1000/1000 VUs` 같은 줄이 나오면 시작된 것이다. 처음에는 이미지를 받느라 30초쯤 걸린다.
- 끝나면 요약이 나오고 명령이 끝난다. 로그는 `results\` 폴더에 저장된다.
- 끝나면 Grafana에서 **초당 요청 수**, **p95 응답 시간**, **5xx 비율**의 최댓값을 보고 `results\README.md` 표에 적는다(8장 참고).

**라운드 사이 (매번):**
1. **10분 기다린다.** 가상 고객 주문이 만료되면서 재고가 돌아온다.
2. 점주 화면 선착순 탭에서 그 상품의 **한도를 다시 100으로 저장**한다. 라운드 동안 팔린 수만큼 남은 수량이 줄어 있기 때문이다.

## 6. 라운드 2: 3,000명 (녹화)

### 6-1. 화면 배치

모니터 하나(1920×1080 기준)를 이렇게 나눈다.

```
┌──────────────────────────────┬─────────────────┐
│                              │ 고객 A (일반 창) │
│   Grafana                    │ 먼저 줄 섬 → 입장 │
│   FreshLink 서비스            ├─────────────────┤
│                              │ 고객 B (시크릿 창)│
│                              │ 늦게 줄 섬 → 대기 │
├──────────────────────────────┴─────────────────┤
│ PowerShell: run-round.ps1 (k6 진행 상황, 작게)    │
└────────────────────────────────────────────────┘
```

1. **Grafana** 창은 Win+← 로 왼쪽 절반에 붙인다.
2. **고객 A**: Chrome 새 창(Ctrl+N) → https://dev.getfreshlink.com → `sim-customer1` 로그인 → 3장의 상품 상세까지 간다. 창을 오른쪽 위에 세로로 길게 둔다.
3. **고객 B**: Chrome 시크릿 창(Ctrl+Shift+N) → `sim-customer2` 로그인 → 같은 상품 상세로 간다. 오른쪽 아래에 둔다.
4. **k6 창**: `load-test` 폴더의 PowerShell을 아래쪽에 작게 둔다.
5. **OBS 설정** (처음 한 번만)
   1. OBS를 연다. 자동 구성 마법사가 뜨면 "녹화에 최적화"를 고르고 기본값으로 끝낸다.
   2. 설정 → 출력에서 녹화 형식을 **mp4**로 한다. 설정 → 비디오에서 해상도를 1920×1080, FPS를 30으로 한다.
   3. 소스 칸의 + → **디스플레이 캡처** → 확인 → 모니터를 고른다.
   4. 마이크가 필요 없으면 오디오 믹서에서 마이크를 끈다.

### 6-2. 실행

1. OBS에서 **녹화 시작**을 누른다.
2. **고객 A**에서 [구매하기]를 누른다. 줄의 첫 번째라 2초 안에 입장한다. 아직 주문하지 않는다(입장권은 5분 유효).
3. k6 창에서 실행한다.
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\run-round.ps1 -Users 3000 -ProductId <상품ID>
   ```
4. `running` 줄이 나오고 **15초 뒤** **고객 B**에서 [구매하기]를 누른다. 순번이 3,000번대로 보인다.
5. **고객 A**로 돌아가 주문하고 토스 **테스트 카드**로 결제한다.
6. Grafana를 보면서 기다린다. 초당 요청 수가 약 1,200까지 오르는지, p95, 5xx, **DB 커넥션 (HikariCP)** 을 본다.
7. 6~7분 뒤 다 팔리면 **고객 B**가 "품절"로 바뀌고 k6 요약이 나온다.
8. Grafana 그래프가 따라올 때까지 2~3분 더 녹화한다. 그다음 Dashboards → **FreshLink AWS (CloudWatch)** 로 바꿔 **RDS CPU·연결 수**를 보여 준다(거의 안 움직였으면 성공).
9. OBS에서 **녹화 중지**를 누른다. 파일은 기본으로 `C:\Users\<이름>\Videos` 에 저장된다.

## 7. 라운드 3: 5,000명 (녹화 없이)

라운드 사이 작업(10분 기다리기, 한도 다시 저장)을 한 다음 실행한다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-round.ps1 -Users 5000 -ProductId <상품ID>
```

여기서 p95가 1초를 넘거나 `queue_not_in_queue`가 0보다 크면, 한계는 3,000명과 5,000명 사이에 있다.
3,000명에서 이미 무너졌다면 2,000명으로 한 번 더 돌린다. 5,000명도 버텼다면 7,000명으로 한 번 더 돌린다(초당 2,800건).
order-service 파드가 재시작했다면 그것도 결과다. 8장 표의 "판정"에 적는다.

## 8. 결과 읽기와 정리

| k6 요약 줄 | 뜻 | 기대 |
| --- | --- | --- |
| `http_req_duration{name:queue_me}` | 순번 조회 응답 시간 | p95 1초 미만 |
| `queue_not_in_queue` | 줄에서 빠진 수 | 0 |
| `queue_errors` | 200이 아닌 순번 응답(503 등) | 0에 가까움 |
| `queue_admitted` | 입장권을 받은 수 | 한도 + 포기한 수(약 100~110) |
| `queue_ordered` | 주문까지 한 수 | **한도 이하**. 넘으면 버그 |
| `queue_sold_out` | 품절을 받고 끝난 수 | 나머지 거의 전부 |

맨 아래 임계값 줄에 ✗가 있으면 그 항목이 기준을 넘은 것이다.
세 라운드 숫자를 `results\README.md` 표에 채우면 발표에서 이렇게 말할 수 있다: "3,000명은 p95 ○ms로 버티고, 5,000명에서는 p95가 ○초로 늘어난다."

결과를 올린다. `main`에 바로 올리지 않고 PR로 올린다.

```powershell
git checkout -b results/openrun-1117
git add results
git commit -m "test(openrun): 1000/3000/5000명 라운드 결과"
git push -u origin results/openrun-1117
```

## 9. 정리

```powershell
kubectl -n freshlink delete job k6-openrun --ignore-not-found
kubectl -n freshlink delete configmap k6-openrun-script k6-openrun-env
aws eks update-nodegroup-config --cluster-name freshlink-dev-eks --nodegroup-name freshlink-dev-nodes --scaling-config desiredSize=2 --region ap-northeast-2
```

- 점주 화면에서 그 상품의 **선착순을 끈다**.
- 가상 고객 주문(`lt-...`)은 10분 뒤 자동으로 만료되고, 줄과 입장권도 Redis에서 저절로 사라진다. 직접 손댈 것은 없다.
- 노드를 2대로 돌리는 걸 잊어도 21:00 스케줄이 0대로 내린다.

## 10. 막혔을 때

| 증상 | 원인과 해결 |
| --- | --- |
| "k6 파드가 뜨지 않았다" | 노드 3대가 아직 안 떴거나(`kubectl get nodes`) NAT가 꺼져 있어(09:00 전, 21:00 후) 이미지를 못 받는다. `kubectl -n freshlink describe pod -l job-name=k6-openrun` 에서 이유를 본다 |
| 순번 응답이 전부 404 | 그 상품이 선착순이 아니거나 상품ID가 틀렸다(3장) |
| 순번 응답이 503 | Valkey 연결 실패다. `kubectl -n freshlink logs deploy/order-service --tail=50` 로 본다 |
| 아무도 입장하지 못한다 | 한도를 다시 저장하지 않았거나 재고가 아직 돌아오지 않았다(라운드 사이 작업) |
| order-service가 재시작됐다 | `kubectl -n freshlink describe pod -l app.kubernetes.io/name=order-service` 에서 `OOMKilled`(메모리 상한 768Mi)인지 본다. 이것도 결과에 적는다 |
| `jcmd`가 `Unable to open socket file /tmp/.java_pid1` 로 실패한다 | 아래 10-1 |

### 10-1. NMT(jcmd)가 order-service JVM에 붙지 않는다

**증상**

앱 이미지는 JRE(`eclipse-temurin:21-jre-noble`)라 앱 컨테이너 안에는 jcmd가 없다(`exec: "jcmd": executable file not found`). 그래서 JDK 디버그 컨테이너를 붙였는데 연결이 실패한다.

```text
$ kubectl debug ... -- jcmd 1 VM.native_memory baseline
com.sun.tools.attach.AttachNotSupportedException: Unable to open socket file /tmp/.java_pid1: target process 1 doesn't respond within 10500ms or HotSpot VM not loaded
```

이때 order-service 로그에는 `Full thread dump`만 여러 번 찍힌다.

**원인**

- 디버그 컨테이너는 앱과 PID는 같이 보지만 파일시스템(`/tmp`)은 따로 쓴다.
- jcmd는 연결 표시 파일 `.attach_pid1`을 `/proc/1/cwd`(앱의 `/app`)에 만들어야 한다. 디버그 컨테이너를 앱과 같은 uid 10001로 띄우면 권한이 없어서(`touch: cannot touch '/proc/1/root/tmp/.attach_pid1': Permission denied`) 자기 `/tmp`에 만든다. JVM은 그 파일을 못 보므로 연결을 열지 않고 스레드 덤프만 찍는다.
- 리눅스 jcmd는 `-J-Djava.io.tmpdir=...`를 무시하므로 이 방법으로는 우회되지 않는다. 또 PowerShell 5.1은 `-J-Djava.io.tmpdir=...`처럼 `-`로 시작하고 `.`이 든 인자를 쪼개므로 작은따옴표로 감싸야 한다.

**해결**

디버그 컨테이너를 root로 띄운다. 파드가 `runAsNonRoot: true`라서 [`k8s/debug-root.json`](k8s/debug-root.json)으로 덮어쓴다.

```json
{
  "securityContext": {
    "runAsUser": 0,
    "runAsGroup": 0,
    "runAsNonRoot": false
  }
}
```

JVM이 만드는 연결 소켓은 앱의 `/tmp`에 생기므로, 디버그 컨테이너의 `/tmp`에 심볼릭 링크를 건다. 레포 루트에서 PowerShell로 실행한다(2026-11-17 dev에서 `Baseline taken` 확인).

```powershell
$pod = kubectl -n freshlink get pod -l app.kubernetes.io/name=order-service -o jsonpath='{.items[0].metadata.name}'

# 부하 전 기준점
kubectl -n freshlink debug $pod -i -q --image=eclipse-temurin:21-jdk-noble --target=app --profile=general --custom=k8s\debug-root.json -- sh -c 'ln -sf /proc/1/root/tmp/.java_pid1 /tmp/.java_pid1; jcmd 1 VM.native_memory baseline'

# 부하 중·후: 기준점 대비 늘어난 양
kubectl -n freshlink debug $pod -i -q --image=eclipse-temurin:21-jdk-noble --target=app --profile=general --custom=k8s\debug-root.json -- sh -c 'ln -sf /proc/1/root/tmp/.java_pid1 /tmp/.java_pid1; jcmd 1 VM.native_memory summary.diff scale=MB'
```

**참고**

- NMT는 앱이 `-XX:NativeMemoryTracking=summary`로 떠 있어야 동작한다(gitops #28, dev order-service만).
- 디버그 컨테이너는 끝난 채로 파드에 기록만 남고, 파드가 재시작되면 사라진다.
