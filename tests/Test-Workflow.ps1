#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $ScratchRoot) { $ScratchRoot = Join-Path $repoRoot '.local/validation/workflow-tests' }
$runRoot = Join-Path ([IO.Path]::GetFullPath($ScratchRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$script:passed = 0
$script:results = [Collections.Generic.List[object]]::new()
function Assert-Workflow([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-FixtureJson([string]$Path, $Value) { $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Read-FixtureJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 }

# Only these test copies are modified. Plan.ps1, Apply.ps1, Init-Config.ps1 and
# FreePolicy.psm1 are copied byte-for-byte; all native calls and prompts are mocked.
$commonShim = @'

function Invoke-NativeTool {
    param([string]$FilePath, [string[]]$Arguments, [int[]]$AcceptedExitCodes = @(0), [string]$WorkingDirectory)
    $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $settings = Get-Content -LiteralPath (Join-Path $fixtureRoot 'mock-settings.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($FilePath -ne 'terraform') { throw 'TEST BLOCK: only mocked terraform is permitted.' }
    $call = @{tool=$FilePath;arguments=$Arguments;password_present=[bool]$env:TF_VAR_mysql_admin_password}
    $call | ConvertTo-Json -Compress -Depth 10 | Add-Content -LiteralPath (Join-Path $fixtureRoot 'mock-native.jsonl') -Encoding utf8
    $exitCode = 0; $stdout = ''
    switch ($Arguments[0]) {
        'init' { }
        'plan' {
            $exitCode = [int]$settings.plan_exit
            if ($exitCode -in @(0,2)) {
                $out = @($Arguments | Where-Object { $_.StartsWith('-out=') })
                if ($out.Count -ne 1) { throw 'TEST BLOCK: saved-plan path missing.' }
                [IO.File]::WriteAllText($out[0].Substring(5), 'SYNTHETIC SAVED PLAN; NOT A TERRAFORM BINARY')
            }
        }
        'show' { $stdout = Get-Content -LiteralPath (Join-Path $fixtureRoot 'mock-plan.json') -Raw }
        'apply' { }
        default { throw 'TEST BLOCK: unrecognized native operation.' }
    }
    if ($exitCode -notin $AcceptedExitCodes) { throw "MOCK native failure exit=$exitCode" }
    [pscustomobject]@{ExitCode=$exitCode;Stdout=$stdout;Stderr=''}
}
function Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $settings = Get-Content -LiteralPath (Join-Path $fixtureRoot 'mock-settings.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($AsSecureString) { return ConvertTo-SecureString 'SyntheticWorkflowSecret!2026' -AsPlainText -Force }
    $manifest = Get-Content -LiteralPath (Join-Path $fixtureRoot '.local/dev/reviewed-plan.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($settings.consent -eq 'tamper-plan') { Add-Content -LiteralPath $manifest.plan_path -Value 'tampered during prompt' }
    if ($settings.consent -eq 'tamper-source') { Add-Content -LiteralPath (Join-Path $fixtureRoot 'main.tf') -Value '# changed during prompt' }
    if ($settings.consent -eq 'tamper-state') { [IO.File]::WriteAllText((Join-Path $fixtureRoot '.local/dev/terraform.tfstate'), '{"synthetic_state_changed_during_approval":true}') }
    if ($settings.consent -eq 'deny') { return 'NO' }
    return "APPLY dev $($manifest.plan_sha256)"
}
Export-ModuleMember -Function *
'@
$preflightMock = @'
param([string]$Environment='dev')
$context = Get-TaskContext $Environment
$fixture = Get-Content -LiteralPath (Join-Path $context.Root 'mock-settings.json') -Raw | ConvertFrom-Json -AsHashtable
if ($fixture.preflight_fail) { throw 'MOCK preflight failed: read-only account verification incomplete.' }
$settings = Read-JsonFile $context.Config
Assert-EnvironmentTarget $context $fixture.tenancy $settings.region $settings.compartment_ocid
$inventory = Get-Content -LiteralPath (Join-Path $context.Root 'mock-inventory.json') -Raw | ConvertFrom-Json -AsHashtable
Write-PrivateJson (Join-Path $context.Directory 'inventory.json') $inventory
Write-PrivateJson (Join-Path $context.Directory 'deployment.tfvars.json') @{free_tier_only=$true}
'@

function New-WorkflowFixture([string]$Name) {
    $root = Join-Path $runRoot $Name
    foreach ($folder in @('scripts/lib','examples','.local/dev/.plans/reviewed')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $folder)) }
    foreach ($name in @('Apply.ps1','Plan.ps1','Init-Config.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/$name") -Destination (Join-Path $root "scripts/$name")
        Assert-Workflow ((Get-FileHash (Join-Path $repoRoot "scripts/$name")).Hash -eq (Get-FileHash (Join-Path $root "scripts/$name")).Hash) 'The script under test must be an exact copy.'
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/lib/FreePolicy.psm1') -Destination (Join-Path $root 'scripts/lib/FreePolicy.psm1')
    $common = Get-Content -LiteralPath (Join-Path $repoRoot 'scripts/lib/Common.psm1') -Raw
    [IO.File]::WriteAllText((Join-Path $root 'scripts/lib/Common.psm1'), $common + "`n" + $commonShim)
    [IO.File]::WriteAllText((Join-Path $root 'scripts/Preflight.ps1'), $preflightMock)
    foreach ($name in @('config','console-review','databases')) { Copy-Item -LiteralPath (Join-Path $repoRoot "examples/$name.json.example") -Destination (Join-Path $root "examples/$name.json.example") }
    [IO.File]::WriteAllText((Join-Path $root 'main.tf'), '# synthetic fixture; never passed to Terraform')
    [IO.File]::WriteAllText((Join-Path $root '.terraform.lock.hcl'), '# synthetic lock; no provider executable')
    $directory = Join-Path $root '.local/dev'
    $settings = @{region='ap-osaka-1';compartment_ocid='ocid1.compartment.oc1..workflow';mysql_enabled=$false;autonomous_databases=@{};servers=@{};internal_tcp_rules=@{};ssh_allowed_cidr='8.8.8.8/32'}
    $target = @{environment='dev';tenancy_ocid='ocid1.tenancy.oc1..workflow';region=$settings.region;compartment_ocid=$settings.compartment_ocid}
    Write-FixtureJson (Join-Path $directory 'config.json') $settings
    Write-FixtureJson (Join-Path $directory 'console-review.json') @{synthetic=$true}
    Write-FixtureJson (Join-Path $directory 'target.json') $target
    Write-FixtureJson (Join-Path $root 'mock-settings.json') @{plan_exit=2;consent='deny';preflight_fail=$false;tenancy=$target.tenancy_ocid}
    $inventory = @{status='VERIFIED';complete=$true;checked_at=[datetimeoffset]::UtcNow.ToString('o');region=$settings.region;home_region=$settings.region;tenancy_ocid=$target.tenancy_ocid;resources=@();limit_availability=@();verified_images=@();mysql_backup_gb=0}
    Write-FixtureJson (Join-Path $root 'mock-inventory.json') $inventory
    Write-FixtureJson (Join-Path $root 'mock-plan.json') @{resource_changes=@();variables=@{synthetic_secret=@{value='SyntheticWorkflowSecret!2026'}}}
    $planPath = Join-Path $directory '.plans/reviewed/deployment.tfplan'
    [IO.File]::WriteAllText($planPath, 'SYNTHETIC SAVED PLAN; NOT A TERRAFORM BINARY')
    Import-Module (Join-Path $root 'scripts/lib/Common.psm1') -Force -DisableNameChecking
    $context = Get-TaskContext 'dev'
    $manifest = @{status='REVIEWED';environment='dev';tenancy_ocid=$target.tenancy_ocid;region=$settings.region;compartment_ocid=$settings.compartment_ocid;plan_path=$planPath;plan_sha256=(Get-FileHash -LiteralPath $planPath).Hash;source_sha256=Get-SourceFingerprint $context;state_sha256='ABSENT';created_at=[datetimeoffset]::UtcNow.ToString('o');summary_path=(Join-Path $directory 'summary.json')}
    Write-FixtureJson (Join-Path $directory 'reviewed-plan.json') $manifest
    return [pscustomobject]@{ Root=$root; Directory=$directory; Manifest=(Join-Path $directory 'reviewed-plan.json'); PlanPath=$planPath; Context=$context }
}
function Get-MockCalls($Fixture) {
    $path = Join-Path $Fixture.Root 'mock-native.jsonl'
    if (Test-Path -LiteralPath $path) { foreach ($line in Get-Content -LiteralPath $path) { $line | ConvertFrom-Json -AsHashtable } }
}
function Assert-NoMockApply($Fixture) { Assert-Workflow (@(Get-MockCalls $Fixture | Where-Object { $_.arguments[0] -eq 'apply' }).Count -eq 0) 'A rejected workflow reached native apply.' }
function Set-MockConsent($Fixture,[string]$Consent) {
    $path = Join-Path $Fixture.Root 'mock-settings.json'
    $settings = Read-FixtureJson $path; $settings.consent = $Consent; Write-FixtureJson $path $settings
}
function Assert-WorkflowThrows([scriptblock]$Action,[string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-Workflow ($null -ne $caught) 'Expected fail-closed exception.'
    Assert-Workflow ($caught.Exception.Message -match $Pattern) "Unexpected error while checking $Pattern : $($caught.Exception.Message)"
}
function Test-WorkflowCase([string]$Name,[scriptblock]$Body) {
    $fixture = New-WorkflowFixture $Name
    # Suppress the script's simulated LIVE/APPLIED host messages; report only the explicit mock test category.
    & $Body $fixture 6>$null
    $script:passed++
    $script:results.Add(@{name=$Name;status='PASS';mode='offline workflow with mocked native Terraform/OCI'})
    Write-Host "PASS [offline workflow/mock]: $Name"
}

$savedEnvironment = @{}
foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_*' }) { $savedEnvironment[$item.Name]=$item.Value }
try {
    Test-WorkflowCase 'apply-no-reviewed-plan' { param($f)
        Remove-Item -LiteralPath $f.Manifest
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '필요한 파일'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-incomplete-plan' { param($f)
        Write-FixtureJson $f.Manifest @{status='INCOMPLETE';environment='dev'}
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '검토 plan'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-stale-plan' { param($f)
        $m=Read-FixtureJson $f.Manifest; $m.created_at=[datetimeoffset]::UtcNow.AddHours(-3).ToString('o'); Write-FixtureJson $f.Manifest $m
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '2시간'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-tampered-plan-hash' { param($f)
        Add-Content -LiteralPath $f.PlanPath -Value 'changed'
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } 'plan 해시'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-plan-outside-environment' { param($f)
        $m=Read-FixtureJson $f.Manifest; $m.plan_path=Join-Path $f.Root 'outside.tfplan'; Write-FixtureJson $f.Manifest $m
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '폴더 밖'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-source-change' { param($f)
        Add-Content -LiteralPath (Join-Path $f.Root 'main.tf') -Value '# changed'
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '소스/설정'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-state-change' { param($f)
        [IO.File]::WriteAllText((Join-Path $f.Directory 'terraform.tfstate'), '{"synthetic_state":true}')
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } 'State 변경'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-target-mismatch' { param($f)
        $m=Read-FixtureJson $f.Manifest; $m.tenancy_ocid='ocid1.tenancy.oc1..other'; Write-FixtureJson $f.Manifest $m
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '대상 계정'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-preflight-failure' { param($f)
        $path=Join-Path $f.Root 'mock-settings.json'; $s=Read-FixtureJson $path; $s.preflight_fail=$true; Write-FixtureJson $path $s
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } 'MOCK preflight failed'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-consent-mismatch' { param($f)
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '명시적 승인'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-plan-changed-during-consent' { param($f)
        Set-MockConsent $f 'tamper-plan'
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '승인 중 파일'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-source-changed-during-consent' { param($f)
        Set-MockConsent $f 'tamper-source'
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '승인 중 파일'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-state-changed-during-consent' { param($f)
        Set-MockConsent $f 'tamper-state'
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev } '승인 중 State'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'apply-exact-approved-saved-plan' { param($f)
        Set-MockConsent $f 'accept'
        & (Join-Path $f.Root 'scripts/Apply.ps1') -Environment dev
        $calls=@(Get-MockCalls $f | Where-Object { $_.arguments[0] -eq 'apply' })
        Assert-Workflow ($calls.Count -eq 1 -and $calls[0].arguments[-1] -eq $f.PlanPath) 'Only the exact reviewed saved plan may reach apply.'
        Assert-Workflow ('-auto-approve' -notin $calls[0].arguments) 'No auto-approve is allowed.'
        Assert-Workflow ((Read-FixtureJson $f.Manifest).status -eq 'APPLIED') 'Successful mocked apply should update the manifest.'
    }
    foreach ($code in @(0,2)) {
        Test-WorkflowCase "plan-exit-$code-and-redacted-summary" { param($f)
            $path=Join-Path $f.Root 'mock-settings.json'; $s=Read-FixtureJson $path; $s.plan_exit=$code; Write-FixtureJson $path $s
            & (Join-Path $f.Root 'scripts/Plan.ps1') -Environment dev
            $m=Read-FixtureJson $f.Manifest
            Assert-Workflow ($m.status -eq 'REVIEWED') 'Plan exit 0 and 2 must both create a reviewed saved plan.'
            $summaryText=Get-Content -LiteralPath $m.summary_path -Raw
            Assert-Workflow ($summaryText -notmatch 'SyntheticWorkflowSecret') 'Redacted summary leaked synthetic sensitive plan data.'
            Assert-Workflow ((Read-FixtureJson $m.summary_path).terraform_exit_code -eq $code) 'Detailed plan exit code must be preserved.'
            Assert-NoMockApply $f
        }
    }
    Test-WorkflowCase 'plan-exit-1-invalidates-old-review-and-clears-secret' { param($f)
        $path=Join-Path $f.Root 'mock-settings.json'; $s=Read-FixtureJson $path; $s.plan_exit=1; Write-FixtureJson $path $s
        $c=Read-FixtureJson $f.Context.Config; $c.mysql_enabled=$true; Write-FixtureJson $f.Context.Config $c
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Plan.ps1') -Environment dev } 'MOCK native failure exit=1'
        Assert-Workflow ((Read-FixtureJson $f.Manifest).status -eq 'INCOMPLETE') 'Failed Plan must invalidate old approval.'
        Assert-Workflow (-not (Test-Path Env:TF_VAR_mysql_admin_password)) 'Prompted secret remained in environment.'
        $planCalls=@(Get-MockCalls $f | Where-Object { $_.arguments[0] -eq 'plan' })
        Assert-Workflow ($planCalls.Count -eq 1 -and $planCalls[0].password_present) 'Synthetic password must only be provided to the intended native plan invocation.'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'plan-preflight-failure-invalidates-old-review' { param($f)
        $path=Join-Path $f.Root 'mock-settings.json'; $s=Read-FixtureJson $path; $s.preflight_fail=$true; Write-FixtureJson $path $s
        Assert-WorkflowThrows { & (Join-Path $f.Root 'scripts/Plan.ps1') -Environment dev } 'MOCK preflight failed'
        Assert-Workflow ((Read-FixtureJson $f.Manifest).status -eq 'INCOMPLETE') 'Failed preflight must invalidate old plan approval.'
        Assert-Workflow (@(Get-MockCalls $f).Count -eq 0) 'No native Terraform should run after failed preflight.'
    }
    Test-WorkflowCase 'init-twice-preserves-input-and-restricts-acl' { param($f)
        # Remove only the two synthetic fixture inputs so the first Init exercises example creation.
        Remove-Item -LiteralPath $f.Context.Config,$f.Context.Review
        & (Join-Path $f.Root 'scripts/Init-Config.ps1') -Environment dev
        $custom=Read-FixtureJson $f.Context.Config; $custom['preserve_me']='synthetic-user-change'; Write-FixtureJson $f.Context.Config $custom
        $before=(Get-FileHash -LiteralPath $f.Context.Config).Hash
        & (Join-Path $f.Root 'scripts/Init-Config.ps1') -Environment dev
        Assert-Workflow ((Get-FileHash -LiteralPath $f.Context.Config).Hash -eq $before) 'Second Init overwrote existing user configuration.'
        Assert-Workflow (Test-Path -LiteralPath (Join-Path $f.Directory 'databases.json')) 'Init must create service database definitions.'
        if ($IsWindows) {
            $acl=Get-Acl -LiteralPath $f.Directory
            Assert-Workflow ($acl.AreAccessRulesProtected -and @($acl.Access).Count -eq 1) 'Environment ACL must be restricted to the current identity.'
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
            Assert-Workflow ($acl.Access[0].IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $sid.Value) 'Environment ACL owner differs from current identity.'
        }
    }
    Test-WorkflowCase 'environment-target-binding-rejects-state-or-account-switch' { param($f)
        Import-Module (Join-Path $f.Root 'scripts/lib/Common.psm1') -Force -DisableNameChecking
        Assert-WorkflowThrows { Assert-EnvironmentTarget $f.Context 'ocid1.tenancy.oc1..other' 'ap-osaka-1' 'ocid1.compartment.oc1..workflow' } '다른 tenancy'
        [IO.File]::WriteAllText((Join-Path $f.Root 'terraform.tfstate'), '{"legacy_synthetic":true}')
        Assert-WorkflowThrows { Assert-EnvironmentTarget $f.Context 'ocid1.tenancy.oc1..workflow' 'ap-osaka-1' 'ocid1.compartment.oc1..workflow' } '루트에 기존 State'
        Assert-NoMockApply $f
    }
    Test-WorkflowCase 'common-native-exitcode-and-secret-masking-local-process' { param($f)
        Import-Module (Join-Path $repoRoot 'scripts/lib/Common.psm1') -Force -DisableNameChecking
        $pwshPath=(Get-Process -Id $PID).Path
        $result=Invoke-NativeTool -FilePath $pwshPath -Arguments @('-NoProfile','-NonInteractive','-Command','exit 2') -AcceptedExitCodes @(0,2)
        Assert-Workflow ($result.ExitCode -eq 2) 'Native detailed exit code 2 was not preserved.'
        $caught=$null
        try { Invoke-NativeTool -FilePath $pwshPath -Arguments @('-NoProfile','-NonInteractive','-Command','[Console]::Error.WriteLine("SyntheticWorkflowSecretMustNotLeak"); exit 7') | Out-Null } catch { $caught=$_ }
        Assert-Workflow ($null -ne $caught -and $caught.Exception.Message -match 'exit=7' -and $caught.Exception.Message -notmatch 'SyntheticWorkflowSecretMustNotLeak') 'Common native failure must propagate exit status without raw secret-bearing stderr.'
        Assert-NoMockApply $f
    }
    Write-FixtureJson (Join-Path $runRoot 'results.json') @{passed=$script:passed;tests=@($script:results.ToArray());live='NOT_RUN';artifacts=$runRoot}
    Write-Host "WORKFLOW TESTS: $script:passed passed (mock Terraform/OCI; real script execution and Windows ACL). Live apply/bootstrap: NOT RUN."
    Write-Host "Preserved synthetic fixtures: $runRoot"
} finally {
    foreach ($item in Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_*' }) { Remove-Item -LiteralPath "Env:$($item.Name)" }
    foreach ($key in $savedEnvironment.Keys) { Set-Item -LiteralPath "Env:$key" -Value $savedEnvironment[$key] }
    Get-Module Common,FreePolicy | Remove-Module -Force
}
