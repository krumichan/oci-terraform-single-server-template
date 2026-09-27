#requires -Version 7.2
[CmdletBinding()]
param([string]$EvidenceDirectory=(Join-Path $PSScriptRoot '../.local/validation'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$env:TF_DATA_DIR=Join-Path $evidence 'terraform-data'
$env:TF_IN_AUTOMATION='true'
foreach ($entry in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_CLI_ARGS*' -or $_.Name -like 'TF_VAR_*' -or $_.Name -eq 'TF_WORKSPACE' }) { Remove-Item -LiteralPath "Env:$($entry.Name)" }
$results=@()
Write-PrivateJson (Join-Path $evidence 'validation-results.json') @{status='INCOMPLETE';started_at=[datetimeoffset]::UtcNow.ToString('o')}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts'),(Join-Path $root 'tests') -File -Recurse | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "PowerShell syntax failed: $($file.Name): $($errors.Message -join '; ')" }
}
$results+=@{test='PowerShell parse';kind='static';exit_code=0;status='PASS'}
# Tests default to apply unless command=plan is explicit. Reject unsafe tests first.
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.tftest.*') {
    $text=Get-Content -Raw -LiteralPath $file.FullName
    Assert-Condition ($file.Extension -eq '.hcl' -and $text -match 'mock_provider\s+"oci"' -and ([regex]::Matches($text,'(?m)^run\s+"').Count -eq [regex]::Matches($text,'command\s*=\s*plan').Count) -and $text -notmatch 'command\s*=\s*apply') '모든 Terraform test는 명시적인 OCI mock + command=plan이어야 합니다.'
}
foreach ($step in @(
    @{name='terraform fmt';args=@('fmt','-check','-recursive');kind='actual'},
    @{name='terraform init';args=@('init','-backend=false','-input=false','-lockfile=readonly');kind='actual'},
    @{name='terraform validate';args=@('validate','-no-color');kind='actual'}
)) {
    $result=Invoke-NativeTool -FilePath terraform -Arguments $step.args -WorkingDirectory $root
    $result.Stdout | Set-Content -LiteralPath (Join-Path $evidence ($step.name.Replace(' ','-')+'.txt'))
    $results+=@{test=$step.name;kind=$step.kind;exit_code=$result.ExitCode;status='PASS'}
    Write-Host "$($step.name): PASS (exit=$($result.ExitCode), $($step.kind))"
}
$schemaRoot=Join-Path $evidence 'schema-root'
New-Item -ItemType Directory -Force -Path $schemaRoot | Out-Null
@'
terraform {
  required_providers {
    oci = {
      source = "oracle/oci"
      version = "= 8.5.0"
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $schemaRoot 'versions.tf')
Copy-Item -LiteralPath (Join-Path $root '.terraform.lock.hcl') -Destination (Join-Path $schemaRoot '.terraform.lock.hcl')
$schema=Invoke-NativeTool -FilePath terraform -Arguments @('providers','schema','-json') -WorkingDirectory $schemaRoot
$schema.Stdout | Set-Content -LiteralPath (Join-Path $evidence 'provider-schema.json')
$provider=($schema.Stdout | ConvertFrom-Json -AsHashtable -Depth 100).provider_schemas['registry.terraform.io/oracle/oci']
Assert-Condition ($provider.resource_schemas.oci_mysql_mysql_db_system.block.attributes.ContainsKey('nsg_ids')) 'MySQL NSG schema mismatch.'
Assert-Condition ($provider.resource_schemas.oci_database_autonomous_database.block.attributes.ContainsKey('is_free_tier')) 'Autonomous free schema mismatch.'
Assert-Condition ((Get-Content -Raw -LiteralPath (Join-Path $root '.terraform.lock.hcl')) -match 'version\s*=\s*"8\.5\.0"') 'Provider lock mismatch.'
$results+=@{test='provider 8.5.0 schema and readonly lock';kind='actual';exit_code=0;status='PASS'}
foreach ($test in @('Test-TerraformPolicy.ps1','Test-Policy.ps1','Test-Database.ps1','Test-Workflow.ps1','Test-Diagnostics.ps1','Test-Iam.ps1','Test-Verify.ps1','Test-PortableDocs.ps1','Test-Onboarding.ps1','Test-Certificate.ps1','Test-OciListContract.ps1')) {
    $arguments=@('-NoProfile','-File',(Join-Path $root "tests/$test"))
    if ($test -eq 'Test-TerraformPolicy.ps1') { $arguments+=@('-PlanDirectory',$evidence) }
    if ($test -eq 'Test-Workflow.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'workflow-tests')) }
    if ($test -eq 'Test-Database.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'database-tests')) }
    if ($test -eq 'Test-Iam.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'iam-tests')) }
    if ($test -eq 'Test-Verify.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'verify-tests')) }
    if ($test -eq 'Test-PortableDocs.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'portable-docs')) }
    if ($test -eq 'Test-Onboarding.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'onboarding-tests')) }
    if ($test -eq 'Test-Certificate.ps1') { $arguments+=@('-ScratchRoot',(Join-Path $evidence 'certificate-tests')) }
    if ($test -eq 'Test-OciListContract.ps1') { $arguments+=@('-EvidenceDirectory',(Join-Path $evidence 'oci-list-contract')) }
    $result=Invoke-NativeTool -FilePath (Get-Process -Id $PID).Path -Arguments $arguments -WorkingDirectory $root
    $result.Stdout | Set-Content -LiteralPath (Join-Path $evidence "$test.txt")
    Write-Host $result.Stdout
    $kind=switch ($test) {
        'Test-TerraformPolicy.ps1' {'real Terraform / mock OCI plans'}
        'Test-Policy.ps1' {'mock fixtures'}
        'Test-Database.ps1' {'actual local wrapper / mock MySQL'}
        'Test-Workflow.ps1' {'actual local workflow / mock OCI and Terraform'}
        'Test-Diagnostics.ps1' {'actual local subprocess / mock errors / static guard'}
        'Test-Iam.ps1' {'mock OCI and manual review / static guard'}
        'Test-Verify.ps1' {'mock OCI and SSH'}
        'Test-PortableDocs.ps1' {'actual isolated copy and prerequisite probe / static contracts'}
        'Test-Onboarding.ps1' {'actual local fixture files / redirected wizard input / no OCI'}
        'Test-Certificate.ps1' {'actual local X509 and files / mock OCI and OpenSSL responses'}
        'Test-OciListContract.ps1' {$(if ($env:OCI_CONTRACT_PYTHON -and $env:OCI_CONTRACT_CLI) {'actual OCI CLI renderer / controlled SDK fixture / mock failures'} else {'mock CLI-output contract; actual renderer NOT_RUN'})}
    }
    $results+=@{test=$test;kind=$kind;exit_code=$result.ExitCode;status='PASS'}
}
$results+=@{test='OCI account, live plan/apply, SSH/cloud-init, actual DB/TLS/grants, billing';kind='live';exit_code=$null;status='NOT_RUN'}
Write-PrivateJson (Join-Path $evidence 'validation-results.json') $results
Write-Host "IMPLEMENTED_OFFLINE_VALIDATED_LIVE_NOT_RUN: $evidence"
