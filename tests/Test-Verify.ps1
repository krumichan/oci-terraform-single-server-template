#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
if (-not $ScratchRoot) { $ScratchRoot=Join-Path ([IO.Path]::GetTempPath()) 'oci-template-verify-tests' }
$runRoot=Join-Path ([IO.Path]::GetFullPath($ScratchRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
Import-Module (Join-Path $repoRoot 'scripts/lib/Ssh.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'scripts/lib/Verification.psm1') -Force -DisableNameChecking
$script:passed=0; $script:results=[Collections.Generic.List[object]]::new()
function Assert-Test([bool]$Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action,[string]$Pattern) { $caught=$null; try { & $Action | Out-Null } catch { $caught=$_ }; Assert-Test ($null -ne $caught) 'Expected fail-closed exception'; Assert-Test ($caught.Exception.Message -match $Pattern) "Unexpected error for $Pattern : $($caught.Exception.Message)" }
function Test-Case([string]$Name,[scriptblock]$Action) { & $Action 6>$null; $script:passed++; $script:results.Add(@{name=$Name;status='PASS';kind='offline/mock'}); Write-Host "PASS [offline/mock]: $Name" }
function Write-Json([string]$Path,$Value) { $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Read-Json([string]$Path) { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -Depth 100 }
function Copy-Json($Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
$directory=Join-Path $runRoot 'OpenSSH'
$service=@{PathName=(Join-Path $directory 'ssh-agent.exe');State='Running'}
Test-Case 'matching Windows service and default pipe accepted' { Assert-WindowsSshAgentState $directory $service ''; Assert-WindowsSshAgentState $directory $service '\\.\pipe\openssh-ssh-agent' }
Test-Case 'missing agent service rejected' { Assert-Throws { Assert-WindowsSshAgentState $directory $null '' } 'SSH_AGENT_ABSENT' }
Test-Case 'stopped agent requires explicit administrator preparation' { $s=Copy-Json $service; $s.State='Stopped'; Assert-Throws { Assert-WindowsSshAgentState $directory $s '' } 'SSH_AGENT_STOPPED' }
Test-Case 'Git Bash socket rejected' { Assert-Throws { Assert-WindowsSshAgentState $directory $service '/tmp/ssh-123/agent.42' } 'SSH_AGENT_MIXED' }
Test-Case 'service executable in different distribution rejected' { $s=Copy-Json $service; $s.PathName=Join-Path $runRoot 'Git/usr/bin/ssh-agent.exe'; Assert-Throws { Assert-WindowsSshAgentState $directory $s '' } 'SSH_AGENT_MIXED' }
Test-Case 'SSH diagnostics never echo stderr secrets' {
    foreach ($pair in @(@('REMOTE HOST IDENTIFICATION HAS CHANGED','SSH_HOST_KEY_MISMATCH_OR_UNKNOWN'),@('Permission denied','SSH_AUTHENTICATION_FAILED'),@('Connection timed out','SSH_CONNECT_TIMEOUT'),@('Connection refused','SSH_NETWORK_UNREACHABLE'),@('unknown failure','SSH_CONNECTION_FAILED'))) { Assert-Test ((Get-SshFailureCode ($pair[0]+' private_key=DO_NOT_EMIT')) -ceq $pair[1]) }
}
$expected=@{db_name='CATONE';db_workload='OLTP';whitelisted_ips=@('8.8.8.8/32')}
$valid=@{id='ocid1.autonomousdatabase.oc1.ap-osaka-1.mock';'compartment-id'='ocid1.compartment.oc1..mock';'db-name'='CATONE';'db-workload'='OLTP';'lifecycle-state'='AVAILABLE';'data-storage-size-in-gbs'=20;'cpu-core-count'=1;'is-free-tier'=$true;'is-mtls-connection-required'=$true;'is-auto-scaling-enabled'=$false;'is-auto-scaling-for-storage-enabled'=$false;'is-dedicated'=$false;'is-dev-tier'=$false;'is-local-data-guard-enabled'=$false;'whitelisted-ips'=@('8.8.8.8/32')}
Test-Case 'Autonomous OFF is NOT_APPLICABLE' { $r=New-AutonomousVerification @{} @{} 'tenancy' 'region' 'compartment'; Assert-Test ($r.status -eq 'NOT_APPLICABLE' -and $r.wallet -eq 'NOT_APPLICABLE'); Assert-AutonomousOutputSet @{} @{} }
Test-Case 'Autonomous pending query is NOT_RUN' { $r=New-AutonomousVerification @{one=$expected} @{one=@{id=$valid.id;db_name='CATONE'}} 'tenancy' 'region' 'compartment'; Assert-Test ($r.status -eq 'NOT_RUN' -and $r.resources[0].api_query -eq 'NOT_RUN' -and $r.wallet -eq 'NOT_RUN' -and $r.database_connection -eq 'NOT_RUN') }
Test-Case 'Autonomous valid response passes without wallet claim' { $r=Test-AutonomousLiveResponse $valid $expected $valid.id $valid['compartment-id']; Assert-Test ($r.status -eq 'PASS' -and $r.wallet -eq 'NOT_RUN' -and $r.database_connection -eq 'NOT_RUN') }
Test-Case 'Autonomous defaults OLTP and accepts normalized Oracle name case' { $e=Copy-Json $expected; $e.Remove('db_workload'); $e.db_name='catone'; $r=Test-AutonomousLiveResponse $valid $e $valid.id $valid['compartment-id']; Assert-Test ($r.status -eq 'PASS') }
foreach ($field in @('id','compartment-id','db-name','db-workload','lifecycle-state','data-storage-size-in-gbs','cpu-core-count','is-free-tier','is-mtls-connection-required','is-auto-scaling-enabled','is-auto-scaling-for-storage-enabled','is-dedicated','is-dev-tier','is-local-data-guard-enabled','whitelisted-ips')) {
    Test-Case "Autonomous rejects absent field $field" { $bad=Copy-Json $valid; $bad.Remove($field); $r=Test-AutonomousLiveResponse $bad $expected $valid.id $valid['compartment-id']; Assert-Test ($r.status -eq 'FAIL') }
}
Test-Case 'Autonomous unsafe paid insecure and overstorage values rejected' {
    $bad=Copy-Json $valid; $bad['is-free-tier']=$false; $bad['is-mtls-connection-required']=$false; $bad['is-auto-scaling-enabled']=$true; $bad['data-storage-size-in-gbs']=1024; $bad['whitelisted-ips']=@('0.0.0.0/0'); $r=Test-AutonomousLiveResponse $bad $expected $valid.id $valid['compartment-id']; Assert-Test ($r.status -eq 'FAIL' -and $r.failed_checks.Count -eq 5)
}
Test-Case 'Autonomous output drift duplicate and third DB rejected' {
    Assert-Throws { Assert-AutonomousOutputSet @{one=$expected} @{} } 'ADB_OUTPUT_SET_MISMATCH'
    Assert-Throws { Assert-AutonomousOutputSet @{one=$expected;two=$expected} @{one=@{id=$valid.id;db_name='CATONE'};two=@{id=$valid.id;db_name='CATONE'}} } 'ADB_DUPLICATE_OCID'
    Assert-Throws { Assert-AutonomousOutputSet @{one=$expected;two=$expected;three=$expected} @{} } 'ADB_COUNT_INVALID'
}
$commonShim=@'
function Get-Mock { Read-JsonFile (Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))) 'mock.json') }
function Get-ProfileIdentity { param([string]$Profile) [pscustomobject]@{Tenancy='ocid1.tenancy.oc1..mock';Profile=$Profile;ConfigPath='mock'} }
function Initialize-Terraform { param($Context) }
function Invoke-NativeTool {
    param([string]$FilePath,[string[]]$Arguments,[int[]]$AcceptedExitCodes=@(0),[string]$WorkingDirectory,[int]$TimeoutSeconds=0)
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')); $m=Get-Mock
    @{tool=[IO.Path]::GetFileName($FilePath);arguments=$Arguments;timeout=$TimeoutSeconds} | ConvertTo-Json -Depth 20 -Compress | Add-Content -LiteralPath (Join-Path $root 'calls.jsonl')
    $code=0; $stdout=''; $stderr=''
    switch ([IO.Path]::GetFileName($FilePath)) {
        'terraform' { if ($Arguments[0] -ne 'output') { throw 'TEST BLOCK: only output allowed' }; $stdout=$m.outputs | ConvertTo-Json -Depth 100 }
        'ssh-keygen.exe' { if ($Arguments[0] -eq '-F') { if ($m.mode -eq 'unknown-host') { $code=1 } else { $stdout='fixture known host' } } else { $stdout='256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA synthetic (ED25519)' } }
        'ssh-add.exe' { switch ($m.mode) { 'no-agent' { $code=2 }; 'no-keys' { $code=1 }; 'wrong-key' { $stdout='256 SHA256:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB synthetic (ED25519)' }; default { $stdout='256 SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA synthetic (ED25519)' } } }
        'ssh.exe' { if ($m.mode -eq 'host-mismatch') { $code=255; $stderr='REMOTE HOST IDENTIFICATION HAS CHANGED private_key=DO_NOT_EMIT' } elseif ($m.mode -eq 'ssh-denied') { $code=255; $stderr='Permission denied private_key=DO_NOT_EMIT' } else { $stdout='synthetic readiness or OS results' } }
        default { throw 'TEST BLOCK: unexpected executable' }
    }
    if ($code -notin $AcceptedExitCodes) { throw 'MOCK_NATIVE_FAILURE' }
    [pscustomobject]@{ExitCode=$code;Stdout=$stdout;Stderr=$stderr}
}
function Invoke-OciJson {
    param($Identity,[string]$Region,[string[]]$Arguments,[switch]$List)
    $root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')); $m=Get-Mock
    @{tool='oci';region=$Region;arguments=$Arguments} | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $root 'calls.jsonl')
    if ($m.mode -eq 'oci-fail') { throw 'MOCK_OCI_PERMISSION_DENIED' }
    if ($Arguments[0] -eq 'db') { return $m.adb[$Arguments[-1]] }
    if ($Arguments[0] -eq 'compute') { return $m.vm }
    throw 'TEST BLOCK: unexpected OCI operation'
}
Export-ModuleMember -Function *
'@
$sshShim=@'
function Get-WindowsSshToolchain { @{Ssh='ssh.exe';Add='ssh-add.exe';Keygen='ssh-keygen.exe';Agent='//./pipe/openssh-ssh-agent';PathClient='MOCK/Git/ssh.exe'} }
Export-ModuleMember -Function Assert-WindowsSshAgentState,Get-WindowsSshToolchain,Get-SshFingerprint,Get-SshFailureCode,Get-SshStrictArguments,Test-SshReadiness
'@
function New-Fixture([string]$Name,[int]$AdbCount=0) {
    $root=Join-Path $runRoot $Name
    foreach ($folder in @('scripts/lib','.local/dev')) { [void][IO.Directory]::CreateDirectory((Join-Path $root $folder)) }
    foreach ($name in @('Verify.ps1','Test-SshReady.ps1')) { Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/$name") -Destination (Join-Path $root "scripts/$name") }
    foreach ($name in @('Common.psm1','Ssh.psm1','Verification.psm1')) { Copy-Item -LiteralPath (Join-Path $repoRoot "scripts/lib/$name") -Destination (Join-Path $root "scripts/lib/$name") }
    Add-Content -LiteralPath (Join-Path $root 'scripts/lib/Common.psm1') -Value $commonShim
    Add-Content -LiteralPath (Join-Path $root 'scripts/lib/Ssh.psm1') -Value $sshShim
    foreach ($name in @('fixture-key','fixture-key.pub','known_hosts')) { Set-Content -LiteralPath (Join-Path $root $name) -Value 'SYNTHETIC FIXTURE ONLY' }
    $config=@{oci_profile='MOCK';region='ap-osaka-1';compartment_ocid=$valid['compartment-id'];ssh_public_key_path=(Join-Path $root 'fixture-key.pub');autonomous_databases=@{}}
    $deployment=@{tenancy_ocid='ocid1.tenancy.oc1..mock';region=$config.region;compartment_ocid=$config.compartment_ocid}
    $outputs=@{deployment=@{value=$deployment};servers=@{value=@{one=@{id='ocid1.instance.oc1.ap-osaka-1.mock';public_ip='203.0.113.10';private_ip='10.0.1.10'}}};mysql=@{value=$null};autonomous_databases=@{value=@{}}}
    $adb=@{}
    for ($i=1;$i -le $AdbCount;$i++) { $key="db$i"; $id="ocid1.autonomousdatabase.oc1.ap-osaka-1.mock$i"; $e=Copy-Json $expected; $e.db_name="CAT$i"; $config.autonomous_databases[$key]=$e; $outputs.autonomous_databases.value[$key]=@{id=$id;db_name=$e.db_name}; $live=Copy-Json $valid; $live.id=$id; $live['db-name']=$e.db_name; $adb[$id]=$live }
    Write-Json (Join-Path $root '.local/dev/config.json') $config
    Write-Json (Join-Path $root 'mock.json') @{mode='normal';outputs=$outputs;adb=$adb;vm=@{id=$outputs.servers.value.one.id;'compartment-id'=$config.compartment_ocid;shape='VM.Standard.E2.1.Micro';'lifecycle-state'='RUNNING'}}
    return @{root=$root;key=(Join-Path $root 'fixture-key');known=(Join-Path $root 'known_hosts');mock=(Join-Path $root 'mock.json');report=(Join-Path $root '.local/dev/verification.json')}
}
function Set-Mode($Fixture,[string]$Mode) { $m=Read-Json $Fixture.mock; $m.mode=$Mode; Write-Json $Fixture.mock $m }
function Get-Calls($Fixture) { $path=Join-Path $Fixture.root 'calls.jsonl'; if (Test-Path $path) { foreach ($line in Get-Content -LiteralPath $path) { $line | ConvertFrom-Json -AsHashtable } } }
foreach ($count in @(0,1,2)) {
    Test-Case "Verify workflow Autonomous $count with agent and strict SSH" {
        $f=New-Fixture "valid-$count" $count
        & (Join-Path $f.root 'scripts/Verify.ps1') -Environment dev -SshPrivateKeyPath $f.key -KnownHostsPath $f.known
        $r=Read-Json $f.report; Assert-Test ($r.status -eq 'PASS'); Assert-Test ($r.autonomous.status -eq $(if ($count) {'PASS'} else {'NOT_APPLICABLE'}))
        $calls=@(Get-Calls $f); $adbCalls=@($calls | Where-Object { $_.tool -eq 'oci' -and $_.arguments[0] -eq 'db' }); Assert-Test ($adbCalls.Count -eq $count)
        foreach ($call in $adbCalls) { Assert-Test ($call.region -eq 'ap-osaka-1' -and $call.arguments[2] -eq 'get') }
        $sshCalls=@($calls | Where-Object { $_.tool -eq 'ssh.exe' }); Assert-Test ($sshCalls.Count -eq 2 -and $sshCalls[0].timeout -eq 30 -and $sshCalls[1].timeout -eq 300)
        foreach ($call in $sshCalls) { Assert-Test ('BatchMode=yes' -in $call.arguments -and 'StrictHostKeyChecking=yes' -in $call.arguments -and 'IdentitiesOnly=yes' -in $call.arguments -and $f.key -notin $call.arguments -and "$($f.key).pub" -in $call.arguments -and 'IdentityAgent=//./pipe/openssh-ssh-agent' -in $call.arguments -and $call.arguments[0] -eq '-F' -and $call.arguments[1] -eq 'none') }
    }
}
foreach ($case in @(@('no-agent','SSH_AGENT_UNREACHABLE'),@('no-keys','SSH_AGENT_NO_KEYS'),@('wrong-key','SSH_AGENT_KEY_MISSING'),@('unknown-host','SSH_HOST_KEY_UNKNOWN'),@('host-mismatch','SSH_HOST_KEY_MISMATCH_OR_UNKNOWN'),@('ssh-denied','SSH_AUTHENTICATION_FAILED'))) {
    Test-Case "Verify fails closed and persists report: $($case[0])" {
        $f=New-Fixture $case[0]; Set-Mode $f $case[0]
        Assert-Throws { & (Join-Path $f.root 'scripts/Verify.ps1') -Environment dev -SshPrivateKeyPath $f.key -KnownHostsPath $f.known } $case[1]
        $r=Read-Json $f.report; Assert-Test ($r.status -eq 'FAIL' -and $r.failure_stage -eq 'ssh-readiness:one' -and $r.checks[0].status -eq 'FAIL'); Assert-Test ((Get-Content -Raw $f.report) -notmatch 'DO_NOT_EMIT')
        Assert-Test (@(Get-Calls $f | Where-Object { $_.tool -eq 'ssh.exe' -and $_.timeout -eq 300 }).Count -eq 0)
    }
}
Test-Case 'local SSH readiness makes no server connection' { $f=New-Fixture 'local-only'; & (Join-Path $f.root 'scripts/Test-SshReady.ps1') -SshPrivateKeyPath $f.key | Out-Null; Assert-Test (@(Get-Calls $f | Where-Object { $_.tool -eq 'ssh.exe' }).Count -eq 0) }
Test-Case 'missing local key cannot launch SSH' { $f=New-Fixture 'missing-key'; Assert-Throws { & (Join-Path $f.root 'scripts/Test-SshReady.ps1') -SshPrivateKeyPath (Join-Path $f.root 'absent') } 'SSH_KEY_MISSING'; Assert-Test (@(Get-Calls $f).Count -eq 0) }
Test-Case 'Verify without SSH marks it NOT_RUN' { $f=New-Fixture 'no-ssh'; & (Join-Path $f.root 'scripts/Verify.ps1') -Environment dev; $r=Read-Json $f.report; Assert-Test ($r.checks[0].ssh_cloud_init_docker -eq 'NOT_RUN' -and $r.checks[0].ssh_connection -eq 'NOT_RUN') }
Test-Case 'Autonomous API failure persists FAIL with later databases NOT_RUN' {
    $f=New-Fixture 'api-failure' 2; Set-Mode $f 'oci-fail'
    Assert-Throws { & (Join-Path $f.root 'scripts/Verify.ps1') -Environment dev } 'MOCK_OCI_PERMISSION_DENIED'
    $r=Read-Json $f.report; Assert-Test ($r.autonomous.status -eq 'FAIL' -and @($r.autonomous.resources | Where-Object {$_.status -eq 'FAIL'}).Count -eq 1 -and @($r.autonomous.resources | Where-Object {$_.status -eq 'NOT_RUN'}).Count -eq 1)
}
Test-Case 'Autonomous paid API response cannot pass Verify' {
    $f=New-Fixture 'paid-adb' 1; $m=Read-Json $f.mock; $id=@($m.adb.Keys)[0]; $m.adb[$id]['is-free-tier']=$false; Write-Json $f.mock $m
    Assert-Throws { & (Join-Path $f.root 'scripts/Verify.ps1') -Environment dev } 'Autonomous 무료'
    $r=Read-Json $f.report; Assert-Test ($r.autonomous.status -eq 'FAIL' -and $r.autonomous.resources[0].api_query -eq 'PASS' -and $r.autonomous.resources[0].status -eq 'FAIL' -and 'is-free-tier' -in $r.autonomous.resources[0].failed_checks)
}
Test-Case 'Autonomous configured but absent State fails instead of OFF' {
    $f=New-Fixture 'missing-adb-output' 1; $m=Read-Json $f.mock; $m.outputs.autonomous_databases.value=@{}; Write-Json $f.mock $m
    Assert-Throws { & (Join-Path $f.root 'scripts/Verify.ps1') -Environment dev } 'ADB_OUTPUT_SET_MISMATCH'
    $r=Read-Json $f.report; Assert-Test ($r.autonomous.status -eq 'FAIL' -and $r.autonomous.resources[0].status -eq 'NOT_RUN')
}
Write-Json (Join-Path $runRoot 'results.json') @{kind='offline/mock';passed=$script:passed;tests=$script:results;live_ssh='NOT_RUN';live_oci='NOT_RUN';agent_service_mutation='NOT_RUN'}
Write-Host "$script:passed offline/mock verification tests passed. Evidence: $runRoot"
