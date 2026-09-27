#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot=(Join-Path $PSScriptRoot '../.local/onboarding-test'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratch=Join-Path ([IO.Path]::GetFullPath($ScratchRoot)) ('run-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
Import-Module (Join-Path $root 'scripts/lib/Onboarding.psm1') -Force -DisableNameChecking
$script:results=@()
$script:fixtureIndex=0
$runtime=(Get-Process -Id $PID).Path
$tenancy='ocid1.tenancy.oc1..aaaaaaaaaaaafakefixture000001'
$compartment='ocid1.compartment.oc1..aaaaaaaaaaaafakefixture000001'
function Assert-True([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Reject([scriptblock]$Action,[string]$Pattern='.') {
    $rejected=$false
    try { & $Action | Out-Null } catch { $rejected=$true; Assert-True ($_.Exception.Message -match $Pattern) ('Unexpected error: '+$_.Exception.Message) }
    Assert-True $rejected 'Expected rejection, but action succeeded.'
}
function Test-Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; $script:results+=@{name=$Name;status='PASS'};Write-Host "PASS: $Name" }
    catch { $script:results+=@{name=$Name;status='FAIL';error=$_.Exception.Message};Write-Host "FAIL: $Name : $($_.Exception.Message)" }
}
function New-Fixture {
    $script:fixtureIndex++
    $path=Join-Path $scratch ('case-'+$script:fixtureIndex)
    [void][IO.Directory]::CreateDirectory($path)
    Copy-Item -LiteralPath (Join-Path $root 'examples') -Destination (Join-Path $path 'examples') -Recurse
    return $path
}
function Initialize-Fixture([string]$Path) {
    $session=Open-SetupSession $Path
    Set-SetupInput $session Region 'ap-tokyo-1'
    Set-SetupInput $session Tenancy $tenancy
    Set-SetupInput $session Compartment $compartment
    Set-SetupInput $session AccountStatus 'TEST FIXTURE ONLY'
    [void](Save-SetupSession $session -InitializeMissing)
}
function Write-FixtureJson([string]$Path,$Object) { $Object | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8 }
function Get-FixtureHashes([string]$Path) {
    $map=@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force)) { $map[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash }
    return ($map | ConvertTo-Json -Compress)
}
function New-DiscoveryFixture {
    return @{
        tenancy_ocid=$tenancy;home_region='ap-tokyo-1';availability_domains=@('fixture:AD-1','fixture:AD-2')
        image_candidates=@(@{id='ocid1.image.oc1.fixture';display_name='fixture';os_version='24.04';size_in_mbs=47000})
        limit_definitions=@(
            @{service_name='compute';name='standard-e2-micro-core-count';description='AMD';scope_type='AD';availability_supported=$true},
            @{service_name='block-storage';name='total-storage-gb';description='Storage';scope_type='REGION';availability_supported=$true},
            @{service_name='block-storage';name='backup-count';description='Backups';scope_type='REGION';availability_supported=$true},
            @{service_name='mysql';name='mysql-free-db-system-count';description='Always Free DB System';scope_type='AD';availability_supported=$true},
            @{service_name='mysql';name='mysql-free-backup-storage';description='Always Free DB System backup';scope_type='REGION';availability_supported=$true}
        )
    }
}
function Invoke-FixtureWizard([string]$Path,[string]$Step,[string[]]$InputLines=@()) {
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'scripts'))) {
        Copy-Item -LiteralPath (Join-Path $root 'scripts') -Destination (Join-Path $Path 'scripts') -Recurse
    }
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$runtime;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach ($arg in @('-NoProfile','-File',(Join-Path $Path 'scripts/Setup.ps1'),'-Step',$Step)) { $start.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        [void]$process.Start()
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        foreach ($line in $InputLines) { $process.StandardInput.WriteLine($line) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(20000)) { $process.Kill($true);$process.WaitForExit();throw 'Wizard subprocess timeout.' }
        return @{exit_code=$process.ExitCode;stdout=$outTask.GetAwaiter().GetResult();stderr=$errTask.GetAwaiter().GetResult()}
    } finally { $process.Dispose() }
}

Test-Case 'Opening a fresh session does not create .local' {
    $path=New-Fixture;$session=Open-SetupSession $path
    Assert-True ($session.Missing.Count -eq 3) 'Three missing settings expected.'
    Assert-True (-not (Test-Path (Join-Path $path '.local'))) 'Read-only opening wrote files.'
}
Test-Case 'Explicit initialization creates three files with all reviews unconfirmed' {
    $path=New-Fixture;$session=Open-SetupSession $path
    $saved=Save-SetupSession $session -InitializeMissing
    Assert-True ($saved.Files.Count -eq 3) 'Wrong file count.'
    $review=Read-SetupJson (Join-Path $path '.local/dev/console-review.json')
    Assert-True (-not $review.official_policy_confirmed -and -not $review.mysql_nsg_iam.user_permissions_confirmed) 'Review was approved.'
}
Test-Case 'Region is saved to matching fields without overwriting unrelated nested values' {
    $path=New-Fixture;Initialize-Fixture $path
    $session=Open-SetupSession $path;$session.Data.config['custom_preserved']=@{nested=@(1,'한글',@{flag=$true})}
    [void](Save-SetupSession $session)
    $session=Open-SetupSession $path;Set-SetupInput $session Region 'ap-osaka-1';[void](Save-SetupSession $session)
    $after=Open-SetupSession $path
    Assert-True ($after.Data.config.region -eq 'ap-osaka-1' -and $after.Data['console-review'].mysql_nsg_iam.region -eq 'ap-osaka-1') 'Region mismatch.'
    Assert-True ($after.Data.config.custom_preserved.nested[2].flag -eq $true) 'Unknown nested value lost.'
}
Test-Case 'Unchanged input preserves exact bytes and creates no backup directory' {
    $path=New-Fixture;Initialize-Fixture $path;$before=Get-FixtureHashes $path
    $session=Open-SetupSession $path;Set-SetupInput $session Region 'ap-tokyo-1';$saved=Save-SetupSession $session -InitializeMissing
    Assert-True (-not $saved.Changed -and (Get-FixtureHashes $path) -eq $before) 'Idempotent save changed files.'
}
Test-Case 'Changed settings reset manual reviews and preserve exact prior bytes in backup' {
    $path=New-Fixture;Initialize-Fixture $path;$reviewPath=Join-Path $path '.local/dev/console-review.json'
    $review=Read-SetupJson $reviewPath;$review.official_policy_confirmed=$true;$review.limits_quotas_reviewed=$true;$review.mysql_nsg_iam.user_permissions_confirmed=$true
    Write-FixtureJson $reviewPath $review
    $before=(Get-FileHash $reviewPath).Hash
    $session=Open-SetupSession $path;Set-SetupInput $session AccountStatus 'Newly checked fixture';$saved=Save-SetupSession $session
    $after=Read-SetupJson $reviewPath
    Assert-True (-not $after.official_policy_confirmed -and -not $after.limits_quotas_reviewed -and -not $after.mysql_nsg_iam.user_permissions_confirmed) 'Stale review inherited.'
    Assert-True ((Get-FileHash (Join-Path $saved.Backup 'console-review.json')).Hash -eq $before) 'Backup differs from original.'
}
foreach ($case in @(
    @('Region','Japan East (Tokyo)'),@('Region','REPLACE_ME'),@('Compartment',$tenancy),@('Tenancy','ocid1.user.oc1..aaaaaaaaaaaaaaaa'),
    @('Profile','../bad'),@('Profile',"hello`nworld"),@('AccountStatus','-----BEGIN PRIVATE KEY-----'),
    @('SshCidr','0.0.0.0/0'),@('SshCidr','10.1.2.3/32'),@('SshCidr','203.0.113.10/32'),@('SshCidr','999.1.2.3/32'),
    @('DatabaseName','db; DROP DATABASE x'),@('DatabaseUser','root%')
)) {
    $kind=$case[0];$value=$case[1]
    Test-Case "Invalid input rejected: $kind / fixture $($script:results.Count)" { Assert-Reject { Assert-SetupValue $kind $value } }
}
Test-Case 'Public IPv4 /32 and commercial OCID formats accepted without claiming validity' {
    Assert-SetupValue SshCidr '8.8.4.4/32'
    Assert-SetupValue Tenancy $tenancy
    Assert-SetupValue Compartment $compartment
}
Test-Case 'Public key path accepted but a private key and non-absolute path rejected' {
    $path=New-Fixture;$pub=Join-Path $path 'fixture.pub'
    [byte[]]$bytes=@(0,0,0,11)+[Text.Encoding]::ASCII.GetBytes('ssh-ed25519')+@(0,0,0,32)+(1..32)
    [IO.File]::WriteAllText($pub,('ssh-ed25519 '+[Convert]::ToBase64String($bytes)+' fixture'))
    Assert-SetupValue SshKey $pub
    Assert-Reject { Assert-SetupValue SshKey './fixture.pub' }
    [IO.File]::WriteAllText($pub,'-----BEGIN OPENSSH PRIVATE KEY-----')
    Assert-Reject { Assert-SetupValue SshKey $pub }
}
Test-Case 'Duplicate and case-only JSON keys are rejected rather than silently dropped' {
    $path=New-Fixture;$file=Join-Path $path 'duplicate.json'
    [IO.File]::WriteAllText($file,'{"x":1,"x":2}')
    Assert-Reject { Read-SetupJson $file } 'SETUP_JSON'
    [IO.File]::WriteAllText($file,'{"x":1,"X":2}')
    Assert-Reject { Read-SetupJson $file } 'SETUP_JSON'
}
Test-Case 'Environment traversal is rejected' { Assert-Reject { Open-SetupSession (New-Fixture) '../elsewhere' } 'SETUP_ENV' }
Test-Case 'Malformed JSON is not replaced with example data' {
    $path=New-Fixture;Initialize-Fixture $path;$file=Join-Path $path '.local/dev/config.json'
    [IO.File]::WriteAllText($file,'{ broken');$before=(Get-FileHash $file).Hash
    Assert-Reject { Open-SetupSession $path }
    Assert-True ((Get-FileHash $file).Hash -eq $before) 'Broken original was overwritten.'
}
Test-Case 'Concurrent edit to any settings document prevents save' {
    $path=New-Fixture;Initialize-Fixture $path;$session=Open-SetupSession $path
    Set-SetupInput $session Region 'ap-osaka-1'
    $file=Join-Path $path '.local/dev/databases.json';[IO.File]::AppendAllText($file,"`n ")
    $before=Get-FixtureHashes $path
    Assert-Reject { Save-SetupSession $session } 'SETUP_CONFLICT'
    Assert-True ((Get-FixtureHashes $path) -eq $before) 'Concurrent edit or other file overwritten.'
}
Test-Case 'Existing fixed target blocks region changes without modifying target or State' {
    $path=New-Fixture;Initialize-Fixture $path
    Write-FixtureJson (Join-Path $path '.local/dev/target.json') @{environment='dev';tenancy_ocid=$tenancy;region='ap-tokyo-1';compartment_ocid=$compartment}
    [IO.File]::WriteAllText((Join-Path $path '.local/dev/terraform.tfstate'),'fixture not a real State')
    $before=Get-FixtureHashes $path;$session=Open-SetupSession $path;Set-SetupInput $session Region 'ap-osaka-1'
    Assert-Reject { Save-SetupSession $session } 'SETUP_TARGET'
    Assert-True ((Get-FixtureHashes $path) -eq $before) 'Target/State modified.'
}
Test-Case 'State without target is never automatically initialized/imported/deleted' {
    $path=New-Fixture;Initialize-Fixture $path
    [IO.File]::WriteAllText((Join-Path $path 'terraform.tfstate'),'fixture')
    $session=Open-SetupSession $path;Set-SetupInput $session AccountStatus 'Changed'
    Assert-Reject { Save-SetupSession $session } 'SETUP_STATE'
}
Test-Case 'Fresh matching discovery is accepted and another tenancy/stale file rejected' {
    $path=New-Fixture;Initialize-Fixture $path;$file=Join-Path $path '.local/dev/discovery.json'
    $discovery=New-DiscoveryFixture;Write-FixtureJson $file $discovery
    $session=Open-SetupSession $path;Assert-True ((Read-SetupDiscovery $session).home_region -eq 'ap-tokyo-1') 'Matching discovery failed.'
    $discovery.tenancy_ocid='other';Write-FixtureJson $file $discovery
    Assert-Reject { Read-SetupDiscovery $session } 'DISCOVERY_TARGET'
    $discovery.tenancy_ocid=$tenancy;Write-FixtureJson $file $discovery
    [IO.File]::SetLastWriteTimeUtc($file,[datetime]::UtcNow.AddDays(-2))
    Assert-Reject { Read-SetupDiscovery $session } 'DISCOVERY_STALE'
}
Test-Case 'Limit choices exclude unsupported/backups and use every configured AD' {
    $path=New-Fixture;$session=Open-SetupSession $path;$config=$session.Data.config;$discovery=New-DiscoveryFixture
    $config.servers['server-1'].availability_domain='fixture:AD-1';$config.servers['server-2'].availability_domain='fixture:AD-2'
    $config.mysql_availability_domain='fixture:AD-2'
    $choices=@(Get-SetupLimitChoices $config $discovery mysql)
    Assert-True ($choices.Count -eq 1) 'Backup limit wrongly offered.'
    $rows=@(New-SetupLimitRows $config $discovery mysql $choices[0]);Assert-True ($rows.Count -eq 1 -and $rows[0].availability_domain -eq 'fixture:AD-2') 'MySQL scope wrong.'
    $amd=@(Get-SetupLimitChoices $config $discovery amd);$rows=@(New-SetupLimitRows $config $discovery amd $amd[0])
    Assert-True ($rows.Count -eq 2) 'One server AD omitted.'
    $storage=@(Get-SetupLimitChoices $config $discovery storage);$rows=@(New-SetupLimitRows $config $discovery storage $storage[0])
    Assert-True ($rows.Count -eq 1 -and $null -eq $rows[0].availability_domain) 'REGION got fake AD.'
    $discovery.limit_definitions[0].availability_supported=$false
    Assert-True (@(Get-SetupLimitChoices $config $discovery amd).Count -eq 0) 'Unsupported limit offered.'
}
Test-Case 'Ambiguous duplicate definitions and unselected AD are blocked' {
    $path=New-Fixture;$session=Open-SetupSession $path;$discovery=New-DiscoveryFixture
    $choice=@(Get-SetupLimitChoices $session.Data.config $discovery amd)[0]
    Assert-Reject { New-SetupLimitRows $session.Data.config $discovery amd $choice } 'LIMIT_AD'
    $discovery.limit_definitions+=Copy-SetupObject $choice
    Assert-Reject { New-SetupLimitRows $session.Data.config $discovery amd $choice } 'LIMIT_AMBIGUOUS'
}
Test-Case 'Status subprocess on a fresh repository does not create .local' {
    $path=New-Fixture;$result=Invoke-FixtureWizard $path Status
    Assert-True ($result.exit_code -eq 0) ('Status failed: '+$result.stderr)
    Assert-True (-not (Test-Path (Join-Path $path '.local'))) 'Status changed files.'
}
Test-Case 'Q and closed stdin cancel without writes' {
    $path=New-Fixture;$result=Invoke-FixtureWizard $path Region @('Q')
    Assert-True ($result.exit_code -eq 0 -and -not (Test-Path (Join-Path $path '.local'))) 'Q did not safely cancel.'
    $result=Invoke-FixtureWizard $path Region @()
    Assert-True ($result.exit_code -eq 0 -and -not (Test-Path (Join-Path $path '.local'))) 'EOF did not safely cancel.'
}
Test-Case 'Entering Y is not approval; exact SAVE writes selected region' {
    $path=New-Fixture;$result=Invoke-FixtureWizard $path Region @('ap-tokyo-1','Y')
    Assert-True ($result.exit_code -eq 0 -and -not (Test-Path (Join-Path $path '.local'))) 'Y caused write.'
    $result=Invoke-FixtureWizard $path Region @('ap-tokyo-1','SAVE')
    Assert-True ($result.exit_code -eq 0) ('SAVE failed: '+$result.stderr)
    Assert-True ((Read-SetupJson (Join-Path $path '.local/dev/config.json')).region -eq 'ap-tokyo-1') 'Region not saved.'
}
Test-Case 'Wizard does not invoke cloud/SQL/apply/install or set manual approval true' {
    $text=(Get-Content -Raw (Join-Path $root 'scripts/Setup.ps1'))+"`n"+(Get-Content -Raw (Join-Path $root 'scripts/lib/Onboarding.psm1'))
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    $parseErrors = @($errors)
    Assert-True ($parseErrors.Count -eq 0) ('Parse failed: '+(($parseErrors | ForEach-Object { $_.Message }) -join ';'))
    $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object { $_.GetCommandName() })
    Assert-True (@($commands | Where-Object { $_ -match '^(oci|terraform|mysql|ssh|winget|Invoke-OciJson|Invoke-NativeTool|Invoke-WebRequest|Set-ExecutionPolicy|Set-Service)$' }).Count -eq 0) 'Wizard acquired external side effects.'
    Assert-True ($text -notmatch '(?m)\.(?:\w+_confirmed|limits_quotas_reviewed)\s*=\s*\$true') 'Review automatically approved.'
}
$failed=@($script:results | Where-Object status -eq 'FAIL').Count
@{kind='ACTUAL_LOCAL_FIXTURE_TESTS_WHEN_EXECUTED';checks=$script:results;passed=@($script:results | Where-Object status -eq 'PASS').Count;failed=$failed;live='NOT_RUN'} |
    ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $scratch 'onboarding-results.json') -Encoding utf8
Write-Host "Evidence: $scratch"
if ($failed) { throw "Onboarding tests failed: $failed" }
Write-Host ('Onboarding PASS: '+$script:results.Count+' checks; no cloud calls.')
