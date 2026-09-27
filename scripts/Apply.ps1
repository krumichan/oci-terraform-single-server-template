#requires -Version 7.2
[CmdletBinding()]
param([string]$Environment='dev')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/FreePolicy.psm1') -Force -DisableNameChecking
$context=Get-TaskContext $Environment
$manifest=Read-JsonFile (Join-Path $context.Directory 'reviewed-plan.json')
Assert-Condition ($manifest.status -eq 'REVIEWED' -and $manifest.environment -eq $Environment) '성공한 검토 plan이 없습니다. Plan.ps1을 먼저 실행하세요.'
Assert-Condition (([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($manifest.created_at)).TotalHours -le 2) 'plan이 2시간 이상 경과했습니다. 다시 Plan 하세요.'
$expectedPrefix=[IO.Path]::GetFullPath((Join-Path $context.Directory '.plans'))+[IO.Path]::DirectorySeparatorChar
$planPath=[IO.Path]::GetFullPath($manifest.plan_path)
Assert-Condition ($planPath.StartsWith($expectedPrefix,[StringComparison]::OrdinalIgnoreCase)) 'saved plan이 환경의 .plans 폴더 밖에 있습니다.'
Assert-Condition ((Get-FileHash -LiteralPath $planPath).Hash -eq $manifest.plan_sha256) 'saved plan 해시 변경. 다시 Plan 하세요.'
Assert-Condition ((Get-SourceFingerprint $context) -eq $manifest.source_sha256) '소스/설정/콘솔 검토/lock 변경. 다시 Plan 하세요.'
$statePath=Join-Path $context.Directory 'terraform.tfstate'
$stateHash=if (Test-Path -LiteralPath $statePath) { (Get-FileHash -LiteralPath $statePath).Hash } else { 'ABSENT' }
Assert-Condition ($stateHash -eq $manifest.state_sha256) 'State 변경. 다시 Plan 하세요.'
& (Join-Path $PSScriptRoot 'Preflight.ps1') -Environment $Environment
$settings=Read-JsonFile $context.Config
$inventory=Read-JsonFile (Join-Path $context.Directory 'inventory.json')
Assert-Condition ($manifest.tenancy_ocid -eq $inventory.tenancy_ocid -and $manifest.region -eq $inventory.region -and $manifest.compartment_ocid -eq $settings.compartment_ocid) '검토 plan의 대상 계정/리전/compartment와 현재 대상이 다릅니다.'
Initialize-Terraform $context
$show=Invoke-NativeTool -FilePath terraform -WorkingDirectory $context.Root -Arguments @('show','-json',$planPath)
$policy=Test-FreePlan -Plan ($show.Stdout | ConvertFrom-Json -AsHashtable -Depth 100) -Inventory $inventory -Config $settings
Write-Host "대상 tenancy: $($manifest.tenancy_ocid)"
Write-Host "region: $($manifest.region) / compartment: $($manifest.compartment_ocid)"
$policy | ConvertTo-Json -Depth 20 | Write-Host
Write-Host "saved plan SHA256: $($manifest.plan_sha256)"
$phrase="APPLY $Environment $($manifest.plan_sha256)"
$answer=Read-Host "위 변경만 승인하려면 정확히 입력: $phrase"
Assert-Condition ($answer -ceq $phrase) '적용 취소: 명시적 승인이 일치하지 않습니다.'
Assert-Condition ((Get-FileHash -LiteralPath $planPath).Hash -eq $manifest.plan_sha256 -and (Get-SourceFingerprint $context) -eq $manifest.source_sha256) '승인 중 파일이 변경되었습니다. 다시 Plan 하세요.'
$currentStateHash=if (Test-Path -LiteralPath $statePath) { (Get-FileHash -LiteralPath $statePath).Hash } else { 'ABSENT' }
Assert-Condition ($currentStateHash -eq $manifest.state_sha256) '승인 중 State가 변경되었습니다. 다시 Plan 하세요.'
Assert-Condition (([datetimeoffset]::UtcNow-[datetimeoffset]::Parse($inventory.checked_at)).TotalMinutes -le 10) '승인 대기 중 계정 확인이 10분 이상 경과했습니다. 다시 Apply를 실행하세요.'
$result=Invoke-NativeTool -FilePath terraform -WorkingDirectory $context.Root -Arguments @('apply','-input=false','-lock-timeout=60s',$planPath) -Operation 'terraform-apply' -DiagnosticScope @{region=$settings.region;compartment_id=$settings.compartment_ocid}
$manifest.status='APPLIED';$manifest.applied_at=[datetimeoffset]::UtcNow.ToString('o')
Write-PrivateJson (Join-Path $context.Directory 'reviewed-plan.json') $manifest
Write-Host 'APPLIED. DB bootstrap은 아직 실행하지 않았습니다. 다음: Verify.ps1'
