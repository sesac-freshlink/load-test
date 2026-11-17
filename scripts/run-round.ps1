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

kubectl -n $ns delete job k6-openrun --ignore-not-found --wait=true
if ($LASTEXITCODE -ne 0) { throw "이전 Job 지우기 실패" }

kubectl -n $ns create configmap k6-openrun-script --from-file="$root\k6\openrun-queue.js" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $ns create configmap k6-openrun-env `
    --from-literal=STORE_ID=$StoreId --from-literal=STORE_NAME="$StoreName" --from-literal=PRODUCT_ID=$ProductId `
    --from-literal=USERS=$Users --from-literal=RAMP_S=$RampSeconds --from-literal=RUN_ID=$runId `
    --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$root\k8s\k6-job.yaml"
if ($LASTEXITCODE -ne 0) { throw "Job 올리기 실패" }

Start-Sleep 5
kubectl -n $ns wait --for=condition=Ready pod -l job-name=k6-openrun --timeout=300s
if ($LASTEXITCODE -ne 0) { throw "k6 파드가 뜨지 않았다. kubectl -n $ns describe pod -l job-name=k6-openrun 로 이유를 본다" }

$out = Join-Path $root "results\$(Get-Date -Format 'yyyyMMdd-HHmm')-users$Users.txt"
Write-Host "라운드 시작: 가상 고객 $Users 명, RUN_ID $runId. 로그는 $out 에도 저장한다"
kubectl -n $ns logs -f job/k6-openrun | Tee-Object -FilePath $out
