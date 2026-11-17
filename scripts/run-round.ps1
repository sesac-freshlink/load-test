# 선착순 부하 테스트 한 라운드: 스크립트·설정 ConfigMap을 올리고, 전 라운드 Job을 지우고, 새 Job을 올려 로그를 results\에 저장한다.
# 실행 (load-test 폴더, dev kubeconfig):
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-round.ps1 -Users 1000 -ProductId 5
param(
    [Parameter(Mandatory = $true)][int]$Users,
    [Parameter(Mandatory = $true)][string]$ProductId,
    [string]$StoreId = "1",
    [string]$StoreName = "프레시 강남점",
    [int]$RampSeconds = 10
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
# 1인 1개가 하루 기준이라 라운드마다 새 가상 고객 ID를 쓴다
$runId = Get-Date -Format "MMddHHmm"
$ns = "freshlink"

# prod에 잘못 돌리지 않게: 지금 kubectl이 dev 클러스터를 가리킬 때만 진행한다
$ctx = kubectl config current-context
if ($ctx -notmatch "freshlink-dev-eks") {
    throw "지금 kubectl 대상이 dev가 아니다 ($ctx). aws eks update-kubeconfig --name freshlink-dev-eks --region ap-northeast-2 로 바꾼 뒤 다시 실행한다"
}

kubectl -n $ns delete job k6-openrun --ignore-not-found --wait=true
if ($LASTEXITCODE -ne 0) { throw "이전 Job 지우기 실패" }

# YAML을 파이프로 넘기지 않는다: Windows PowerShell 5.1은 파이프에서 한글을 깨뜨려 설정 ConfigMap이 만들어지지 않았다(11/17)
kubectl -n $ns delete configmap k6-openrun-script k6-openrun-env --ignore-not-found
kubectl -n $ns create configmap k6-openrun-script --from-file="$root\k6\openrun-queue.js"
if ($LASTEXITCODE -ne 0) { throw "스크립트 ConfigMap 만들기 실패" }
kubectl -n $ns create configmap k6-openrun-env `
    --from-literal=STORE_ID=$StoreId --from-literal=STORE_NAME="$StoreName" --from-literal=PRODUCT_ID=$ProductId `
    --from-literal=USERS=$Users --from-literal=RAMP_S=$RampSeconds --from-literal=RUN_ID=$runId
if ($LASTEXITCODE -ne 0) { throw "설정 ConfigMap 만들기 실패" }
kubectl apply -f "$root\k8s\k6-job.yaml"
if ($LASTEXITCODE -ne 0) { throw "Job 올리기 실패" }

Start-Sleep 5
kubectl -n $ns wait --for=condition=Ready pod -l job-name=k6-openrun --timeout=300s
if ($LASTEXITCODE -ne 0) { throw "k6 파드가 뜨지 않았다. kubectl -n $ns describe pod -l job-name=k6-openrun 로 이유를 본다" }

$out = Join-Path $root "results\$(Get-Date -Format 'yyyyMMdd-HHmm')-users$Users.txt"
Write-Host "라운드 시작: 가상 고객 $Users 명, RUN_ID $runId. 로그는 $out 에도 저장한다"
kubectl -n $ns logs -f job/k6-openrun | Tee-Object -FilePath $out
