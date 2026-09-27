#requires -Version 7.2
[CmdletBinding()]
param([string]$Environment='dev')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/FreePolicy.psm1') -Force -DisableNameChecking
$context=Get-TaskContext $Environment
$pointer=Join-Path $context.Directory 'reviewed-plan.json'
Write-PrivateJson $pointer @{status='INCOMPLETE'}
& (Join-Path $PSScriptRoot 'Preflight.ps1') -Environment $Environment
$settings=Read-JsonFile $context.Config
$inventory=Read-JsonFile (Join-Path $context.Directory 'inventory.json')
Initialize-Terraform $context
$stamp=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$planDirectory=Join-Path $context.Directory ".plans/$stamp"
New-Item -ItemType Directory -Path $planDirectory | Out-Null
$planPath=Join-Path $planDirectory 'deployment.tfplan'
try {
    if ($settings.mysql_enabled) {
        $secure=Read-Host 'MySQL 관리자 비밀번호 (기존 배포 재plan이면 동일한 현재 비밀번호)' -AsSecureString
        $env:TF_VAR_mysql_admin_password=[Net.NetworkCredential]::new('', $secure).Password
        $secure.Dispose()
    }
    if ($settings.autonomous_databases.Count -gt 0) {
        $passwords=@{}
        foreach ($key in $settings.autonomous_databases.Keys) {
            $secure=Read-Host "Oracle Autonomous $key ADMIN 비밀번호" -AsSecureString
            $passwords[$key]=[Net.NetworkCredential]::new('', $secure).Password
            $secure.Dispose()
        }
        $env:TF_VAR_autonomous_admin_passwords=$passwords | ConvertTo-Json -Compress
    }
    $result=Invoke-NativeTool -FilePath terraform -WorkingDirectory $context.Root -Arguments @('plan','-input=false','-lock-timeout=60s','-detailed-exitcode',"-var-file=$(Join-Path $context.Directory 'deployment.tfvars.json')","-out=$planPath") -AcceptedExitCodes @(0,2) -Operation 'terraform-plan' -DiagnosticScope @{region=$settings.region;compartment_id=$settings.compartment_ocid}
} finally {
    Remove-Item Env:TF_VAR_mysql_admin_password,Env:TF_VAR_autonomous_admin_passwords -ErrorAction SilentlyContinue
    if (Get-Variable passwords -ErrorAction SilentlyContinue) { $passwords.Clear() }
}
$show=Invoke-NativeTool -FilePath terraform -WorkingDirectory $context.Root -Arguments @('show','-json',$planPath)
$plan=$show.Stdout | ConvertFrom-Json -AsHashtable -Depth 100
$policy=Test-FreePlan -Plan $plan -Inventory $inventory -Config $settings
# Raw plan JSON contains passwords; keep only the saved binary and redacted allowlist summary.
$summary=@{tenancy_ocid=$inventory.tenancy_ocid;region=$inventory.region;compartment_ocid=$settings.compartment_ocid;terraform_exit_code=$result.ExitCode;policy=$policy}
Write-PrivateJson (Join-Path $planDirectory 'summary.json') $summary
$statePath=Join-Path $context.Directory 'terraform.tfstate'
$stateHash=if (Test-Path -LiteralPath $statePath) { (Get-FileHash -LiteralPath $statePath).Hash } else { 'ABSENT' }
$manifest=@{status='REVIEWED';environment=$Environment;tenancy_ocid=$inventory.tenancy_ocid;region=$inventory.region;compartment_ocid=$settings.compartment_ocid;plan_path=$planPath;plan_sha256=(Get-FileHash -LiteralPath $planPath).Hash;source_sha256=Get-SourceFingerprint $context;state_sha256=$stateHash;created_at=[datetimeoffset]::UtcNow.ToString('o');summary_path=(Join-Path $planDirectory 'summary.json')}
Write-PrivateJson $pointer $manifest
$summary | ConvertTo-Json -Depth 20 | Write-Host
Write-Host "LIVE_PLAN_VERIFIED_AWAITING_APPLY_APPROVAL: $planPath"
Write-Host "다음 명령: pwsh -File scripts/Apply.ps1 -Environment $Environment"
Write-Host 'Apply는 전체 계정/무료 검사를 다시 실행하고 대상/변경 목록/해시를 보여준 뒤 명시적 승인 문구를 받습니다.'
