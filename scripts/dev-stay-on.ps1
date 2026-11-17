# 오늘 밤만 dev를 21:00에 끄지 않게 한다 (부하 테스트용, 2026-11-17).
# -Disable: 21:00 노드 0대, 21:00 RDS 끄기, 21:10 NAT 삭제 일정을 멈춘다.
# -Enable : 다시 켠다. 23:00 안전 끄기(노드·RDS)와 23:05 NAT 정리는 건드리지 않으므로, 켜 두면 그때 알아서 꺼진다.
# 실행: powershell -ExecutionPolicy Bypass -File .\dev-stay-on.ps1 -Disable   (끝나면 -Enable)
param([switch]$Disable, [switch]$Enable)
$ErrorActionPreference = "Stop"
$env:AWS_CLI_FILE_ENCODING = "UTF-8"
$env:PYTHONUTF8 = "1"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if ($Disable -eq $Enable) { throw "-Disable 또는 -Enable 중 하나만 준다" }
if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = "freshlink-admin" }
$state = if ($Disable) { "DISABLED" } else { "ENABLED" }

$targets = @(
    @{ g = "freshlink-dev"; n = "freshlink-dev-nodes-down" },
    @{ g = "freshlink-dev"; n = "freshlink-dev-rds-stop" },
    @{ g = "freshlink-dev-workflow-dispatch"; n = "freshlink-dev-workflow-dispatch-nat-off" }
)
$tmp = Join-Path $env:TEMP "freshlink-schedule.json"
foreach ($t in $targets) {
    $json = aws scheduler get-schedule --group-name $t.g --name $t.n --region ap-northeast-2 --output json
    if ($LASTEXITCODE -ne 0) { throw "$($t.n) 읽기 실패" }
    $s = ($json -join "`n") | ConvertFrom-Json
    # update-schedule은 일정 전체를 다시 보내야 한다. 읽은 값 그대로 두고 State만 바꾼다
    $in = [ordered]@{
        Name = $s.Name; GroupName = $s.GroupName; ScheduleExpression = $s.ScheduleExpression
        FlexibleTimeWindow = $s.FlexibleTimeWindow; Target = $s.Target; State = $state
    }
    foreach ($k in "ScheduleExpressionTimezone", "Description", "StartDate", "EndDate", "ActionAfterCompletion", "KmsKeyArn") {
        if ($s.$k) { $in[$k] = $s.$k }
    }
    [System.IO.File]::WriteAllText($tmp, ($in | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
    aws scheduler update-schedule --cli-input-json "file://$tmp" --region ap-northeast-2 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$($t.n) 바꾸기 실패" }
    $now = aws scheduler get-schedule --group-name $t.g --name $t.n --region ap-northeast-2 --query State --output text
    Write-Host "$($t.n): $now"
}
Write-Host "끝. -Disable 했다면 테스트가 끝난 뒤 꼭 -Enable 을 실행한다 (안 하면 내일부터 21:00에 안 꺼진다)"
