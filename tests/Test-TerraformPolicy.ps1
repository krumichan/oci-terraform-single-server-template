#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$PlanDirectory = (Join-Path $PSScriptRoot '../.local/validation'),
    [string]$TerraformPath = 'terraform'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$evidence = [IO.Path]::GetFullPath($PlanDirectory)
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
@{status='INCOMPLETE';kind='offline/mock';live_run=$false;started_at=[datetimeoffset]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath (Join-Path $evidence 'terraform-policy-results.json')
Import-Module (Join-Path $root 'scripts/lib/FreePolicy.psm1') -Force -DisableNameChecking

function Require-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "TERRAFORM_POLICY_TEST_FAILED: $Message" }
}

# Execute only this maintained test file. Terraform test defaults to apply, so
# refuse any run without an explicit plan command or any non-mock provider.
$testFile = Join-Path $root 'tests/free_tier.tftest.hcl'
$testSource = Get-Content -Raw -LiteralPath $testFile
$runCount = [regex]::Matches($testSource, '(?m)^run\s+"').Count
Require-Test ($runCount -gt 0 -and $testSource -match '(?m)^mock_provider\s+"oci"\s*\{') 'OCI mock provider is required.'
Require-Test ($runCount -eq [regex]::Matches($testSource, '(?m)^\s*command\s*=\s*plan\s*$').Count) 'Every run must explicitly use command=plan.'
Require-Test ($testSource -notmatch '(?m)^\s*(provider\s+"|providers\s*=|module\s*\{|command\s*=\s*apply)') 'Live provider/module/apply overrides are not allowed.'
Require-Test (@(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '(\.auto\.tfvars(\.json)?$|^terraform\.tfvars(\.json)?$)' }).Count -eq 0) 'Root auto-loaded tfvars must be preserved elsewhere before offline tests; refusing to read account inputs.'

$names = @('default_two_vm_mysql', 'single_vm_mysql_off', 'map_order_and_pinned_images', 'explicit_https_and_internal_only', 'autonomous_one', 'autonomous_two')
$plans = @{}
$testSummary = $null
$diagnostics = [Collections.Generic.List[object]]::new()
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = (Get-Command -Name $TerraformPath -ErrorAction Stop).Source
$start.WorkingDirectory = $root
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$relativeTestFile = [IO.Path]::GetRelativePath($root, $testFile)
foreach ($argument in @('test', '-json', '-verbose', "-filter=$relativeTestFile")) { $start.ArgumentList.Add($argument) }
foreach ($key in @($start.Environment.Keys)) {
    if ($key -like 'TF_CLI_ARGS*' -or $key -like 'TF_VAR_*' -or $key -eq 'TF_WORKSPACE') { [void]$start.Environment.Remove($key) }
}
$start.Environment['TF_IN_AUTOMATION'] = 'true'
if (-not $start.Environment['TF_DATA_DIR']) { $start.Environment['TF_DATA_DIR'] = Join-Path $evidence 'terraform-data' }

$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$started = $false
try {
    $started = $process.Start()
    Require-Test $started 'Failed to start Terraform.'
    # Drain stderr concurrently, and handle stdout one JSON line at a time.
    # Provider schema is repeated in verbose output (~100 MB overall); discard
    # those copies immediately instead of saving or collecting the full stream.
    $stderrTask = $process.StandardError.ReadToEndAsync()
    while ($null -ne ($line = $process.StandardOutput.ReadLine())) {
        if ($line -match '"type"\s*:\s*"test_plan"') {
            if ($line -match '"@testrun"\s*:\s*"([^"]+)"' -and $Matches[1] -in $names) {
                $event = $line | ConvertFrom-Json -AsHashtable -Depth 100
                $name = $event['@testrun']
                Require-Test (-not $plans.ContainsKey($name)) "Duplicate test plan: $name"
                $plan = $event.test_plan
                $compact = @{format_version=$plan.plan_format_version; resource_changes=$plan.resource_changes; output_changes=$plan.output_changes}
                $plans[$name] = $compact
                $compact | ConvertTo-Json -Depth 100 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $evidence "mock-$name.plan.json")
                $event = $null
                $plan = $null
            }
        } elseif ($line -match '"type"\s*:\s*"test_summary"') {
            $testSummary = ($line | ConvertFrom-Json -AsHashtable).test_summary
        } elseif ($line -match '"type"\s*:\s*"diagnostic"') {
            $event = $line | ConvertFrom-Json -AsHashtable -Depth 100
            # Static test diagnostics only; never echo plan or provider schema.
            $diagnostics.Add(@{severity=$event.diagnostic.severity;summary=$event.diagnostic.summary;detail=$event.diagnostic.detail})
        }
    }
    $process.WaitForExit()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) {
        $diagnostics | ConvertTo-Json -Depth 12 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $evidence 'terraform-policy-diagnostics.json')
        $stderr | Set-Content -Encoding utf8 -LiteralPath (Join-Path $evidence 'terraform-policy-stderr.log')
        throw "Terraform mock test failed (exit=$($process.ExitCode)); inspect terraform-policy-diagnostics.json and terraform-policy-stderr.log."
    }
} finally {
    if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    $process.Dispose()
}
Require-Test ($null -ne $testSummary -and $testSummary.status -eq 'pass' -and $testSummary.passed -eq $runCount -and $testSummary.failed -eq 0 -and $testSummary.errored -eq 0) 'Terraform mock test summary was incomplete.'
Require-Test ($plans.Count -eq $names.Count) 'All six freshly generated positive plans must be present.'
Write-Host "PASS Terraform mock plan tests: $($testSummary.passed) passed (no live OCI/apply)."

$integration = @()
foreach ($name in $names) {
    $config = @{
        region='ap-tokyo-1'; compartment_ocid='ocid1.compartment.oc1..mock'; ssh_allowed_cidr='203.0.113.10/32'
        servers=@{
            'server-1'=@{private_ip='10.0.1.10';public_https=$false}
            'server-2'=@{private_ip='10.0.1.11';public_https=$false}
        }
        internal_tcp_rules=@{};mysql_enabled=$true;autonomous_databases=@{}
    }
    $expected = @{amd=2;mysql=1;autonomous=0;compute_storage_gb=100}
    if ($name -eq 'single_vm_mysql_off') {
        $config.servers.Remove('server-2'); $config.mysql_enabled=$false
        $expected.amd=1; $expected.mysql=0; $expected.compute_storage_gb=50
    }
    if ($name -eq 'explicit_https_and_internal_only') {
        $config.servers['server-1'].public_https=$true
        $config.internal_tcp_rules=@{api=@{source_server='server-1';destination_server='server-2';port=8080}}
    }
    if ($name -eq 'autonomous_one') {
        $config.autonomous_databases=@{analytics=@{db_name='catdata';whitelisted_ips=@('203.0.113.10/32')}}
        $expected.autonomous=1
    }
    if ($name -eq 'autonomous_two') {
        $config.autonomous_databases=@{
            first=@{db_name='catfirst';whitelisted_ips=@('203.0.113.10/32')}
            second=@{db_name='catsecond';whitelisted_ips=@('203.0.113.10/32')}
        }
        $expected.autonomous=2
    }
    # Deliberately injected fixture inventory, never evidence of a real account.
    $inventory = @{
        status='VERIFIED';complete=$true;checked_at=[datetimeoffset]::UtcNow.ToString('o')
        region='ap-tokyo-1';home_region='ap-tokyo-1';resources=@();mysql_backup_gb=0
        verified_images=@('ocid1.image.oc1.ap-tokyo-1.mockone','ocid1.image.oc1.ap-tokyo-1.mocktwo')
        limit_availability=@(
            @{role='amd';scope_type='AD';availability_domain='MOCK:AP-TOKYO-1-AD-1';available=2},
            @{role='storage';scope_type='AD';availability_domain='MOCK:AP-TOKYO-1-AD-1';available=200},
            @{role='mysql';scope_type='AD';availability_domain='MOCK:AP-TOKYO-1-AD-1';available=1},
            @{role='autonomous';scope_type='REGION';availability_domain=$null;available=2}
        )
    }
    $result = Test-FreePlan -Plan $plans[$name] -Inventory $inventory -Config $config
    Require-Test ($result.status -eq 'PASS') "Policy rejected actual mock plan: $name"
    foreach ($key in $expected.Keys) { Require-Test ($result.peak[$key] -eq $expected[$key]) "Unexpected $key peak for $name" }
    $integration += @{test=$name;kind='actual Terraform mock plan + fixture inventory';status='PASS';peak=$result.peak}
    Write-Host "PASS Terraform-to-policy integration: $name"
}

function Get-KnownVmPlan($Plan) {
    @($Plan.resource_changes | Where-Object { $_.type -eq 'oci_core_instance' } | Sort-Object address | ForEach-Object {
        [ordered]@{address=$_.address;actions=$_.change.actions;after=$_.change.after}
    }) | ConvertTo-Json -Depth 100 -Compress
}
Require-Test ((Get-KnownVmPlan $plans.default_two_vm_mysql) -eq (Get-KnownVmPlan $plans.map_order_and_pinned_images)) 'Changing map input order changed VM addresses/actions/known values.'
Write-Host 'PASS Map reorder: all VM addresses, actions and known plan values unchanged.'
$summary = @{
    status='PASS';kind='offline/mock';live_run=$false;terraform_tests_passed=$testSummary.passed
    policy_integrations_passed=$integration.Count;map_order_comparison='PASS';integrations=$integration
}
$summary | ConvertTo-Json -Depth 16 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $evidence 'terraform-policy-results.json')
Write-Host "Terraform mock tests=$($testSummary.passed); real mock-plan policy integrations=$($integration.Count); live=NOT_RUN."
