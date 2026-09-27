#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot=(Join-Path $PSScriptRoot '../.local/portable-docs-test'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scratch=[IO.Path]::GetFullPath($ScratchRoot)
$copy=Join-Path $scratch ('standalone-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($copy)
$script:passed=0
$docNames=@('GETTING_STARTED.md','TOOLS_WINDOWS.md','ACCOUNT_SETUP.md','SSH_AND_DISCOVERY.md','REVIEW_AND_DEPLOY.md','CONNECT_AND_DATABASE.md','OPERATIONS.md','SOURCES.md','PROCEDURE_REFERENCE.md')
function Assert-Test([bool]$Condition,[string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" };$script:passed++;Write-Host "PASS: $Name"
}
# 사용자 설정/State/키/기존 git 이력은 복사하지 않는 독립 배포본 검사다.
foreach ($name in @('README.md','.terraform.lock.hcl','docs','examples','scripts','tests','cloud-init')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $copy $name) -Recurse
}
foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.tf' -File) { Copy-Item -LiteralPath $file.FullName -Destination $copy }
function Test-DocumentContract([string]$Directory) {
    $base=[IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $setupText=Get-Content -Raw -LiteralPath (Join-Path $Directory 'scripts/Setup.ps1')
    $allowedSteps=@('Menu','Region','Tenancy','AccountStatus','Compartment','Profile','SshKey','SshCidr','Placement','Limits','Databases','Status')
    $files=@('README.md')+@($docNames | ForEach-Object { "docs/$_" })
    foreach ($name in $files) {
        $path=Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "DOC_MISSING:$name" }
        $content=Get-Content -Raw -LiteralPath $path
        if ($content -match 'C:\\workspace\\project-cat|\.\.\/CatPjt-TranslaCat-docs|\.codex-workspace[^\r\n]*tools') { throw "AUTHOR_PATH:$name" }
        foreach ($match in [regex]::Matches($content,'\]\(([^)]+)\)')) {
            $target=$match.Groups[1].Value
            if ($target -match '^https?://|^mailto:|^#') { continue }
            $target=($target -split '#',2)[0]
            $resolved=[IO.Path]::GetFullPath((Join-Path (Split-Path $path -Parent) $target))
            if (-not $resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw "OUTSIDE_REPOSITORY:${name}:$target" }
            if (-not (Test-Path -LiteralPath $resolved)) { throw "BROKEN_LINK:${name}:$target" }
        }
        foreach ($match in [regex]::Matches($content,'\.\\(?:scripts|tests)\\([A-Za-z0-9-]+\.ps1)')) {
            $relative=$match.Value.Substring(2).Replace('\','/')
            if (-not (Test-Path -LiteralPath (Join-Path $Directory $relative))) { throw "SCRIPT_MISSING:$relative" }
        }
        foreach ($match in [regex]::Matches($content,'Setup\.ps1[^\r\n]*?-Step ([A-Za-z]+)')) {
            $step=$match.Groups[1].Value
            if ($step -notin $allowedSteps -or -not $setupText.Contains("'$step'")) { throw "SETUP_STEP:$name/$step" }
        }
        if ([regex]::Matches($content,'(?m)^```').Count % 2 -ne 0) { throw "FENCE_PAIR:$name" }
        foreach ($block in [regex]::Matches($content,'(?ms)^```powershell\r?\n(.*?)^```')) {
            $commandText=$block.Groups[1].Value
            $tokens=$null;$errors=$null
            [void][Management.Automation.Language.Parser]::ParseInput($commandText,[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "COMMAND_PARSE:${name}:$($errors.Message -join ';')" }
            if ($commandText -notmatch 'OpenSSH\\ssh\.exe') { continue }
            # -V 단독 호출은 원격 접속이 아닌 로컬 버전 확인이다.
            if ($commandText.Trim() -match '^&\s+"\$env:WINDIR\\System32\\OpenSSH\\ssh\.exe"\s+-V\s*$') { continue }
            foreach ($required in @("'-F','none'",'IdentityAgent=//./pipe/openssh-ssh-agent','IdentitiesOnly=yes','GlobalKnownHostsFile=none','UserKnownHostsFile=','PasswordAuthentication=no','KbdInteractiveAuthentication=no','UpdateHostKeys=no')) {
                if (-not $commandText.Contains($required)) { throw "SSH_AMBIENT_CONFIG:$name" }
            }
            if (-not $commandText.Contains("Join-Path `$HOME '.ssh\known_hosts'")) { throw "SSH_KNOWN_HOSTS:$name" }
            if ($commandText -notmatch '''-i'',"\$sshKey(?:Path)?\.pub"') { throw "SSH_PUBLIC_IDENTITY:$name" }
            if ($commandText -match 'sshTunnelArgs' -and ($commandText -notmatch 'BatchMode=yes' -or $commandText -notmatch 'StrictHostKeyChecking=yes' -or $commandText -notmatch '127\.0\.0\.1:13306:')) { throw "SSH_TUNNEL_CONTRACT:$name" }
            if ($commandText -match 'sshFirstArgs' -and $commandText -notmatch 'StrictHostKeyChecking=ask') { throw "SSH_FIRST_HOST_CONFIRMATION:$name" }
        }
    }
    $guide=Get-Content -Raw -LiteralPath (Join-Path $Directory 'docs/GETTING_STARTED.md')
    if (($guide -split "`n").Count -gt 130) { throw 'ENTRY_TOO_LONG' }
    foreach ($required in @('`mysql MISSING`이어도 지금은 정상입니다.','`pwsh`, `terraform`, `oci`, `ssh` 네 가지','CONNECT_AND_DATABASE.md#mysql-client')) {
        if (-not $guide.Contains($required)) { throw "MYSQL_DEFERRED_GUIDE:$required" }
    }
    foreach ($chapter in @('TOOLS_WINDOWS.md','ACCOUNT_SETUP.md','SSH_AND_DISCOVERY.md','REVIEW_AND_DEPLOY.md','CONNECT_AND_DATABASE.md')) {
        if (-not $guide.Contains($chapter)) { throw "CHAPTER_NAV:$chapter" }
        $text=Get-Content -Raw -LiteralPath (Join-Path $Directory "docs/$chapter")
        if (-not $text.Contains('완료 확인') -or -not $text.Contains('PowerShell')) { throw "CHAPTER_ACTION:$chapter" }
    }
    $account=Get-Content -Raw -LiteralPath (Join-Path $Directory 'docs/ACCOUNT_SETUP.md')
    foreach ($step in @('Region','Tenancy','AccountStatus','Compartment','Profile')) {
        if (-not $account.Contains("-Step $step")) { throw "ACCOUNT_STEP:$step" }
    }
    $connection=Get-Content -Raw -LiteralPath (Join-Path $Directory 'docs/CONNECT_AND_DATABASE.md')
    if (-not $connection.Contains('<a id="mysql-client"></a>')) { throw 'MYSQL_CLIENT_ANCHOR' }
    foreach ($required in @('server-1과 server-2 두 서버 각각','$settings.servers.Keys','foreach ($server in $serversToTrust)')) {
        if (-not $connection.Contains($required)) { throw 'SSH_ALL_SERVERS' }
    }
    foreach ($required in @('VERIFY_IDENTITY','VERIFY_CA','ExpectedCaFileSha256','BOOTSTRAP','TRUST CERTIFICATE')) {
        if (-not $connection.Contains($required)) { throw "TLS_APPROVAL:$required" }
    }
    $tools=Get-Content -Raw -LiteralPath (Join-Path $Directory 'docs/TOOLS_WINDOWS.md')
    if (-not $tools.Contains('oci-cli==3.94.0') -or -not $tools.Contains('LongPathsEnabled')) { throw 'PINNED_INSTALL' }
    $sync=Get-Content -Raw -LiteralPath (Join-Path $Directory 'scripts/Sync-Docs.ps1')
    foreach ($name in $docNames) { if (-not $sync.Contains("'$name'")) { throw "SYNC_MANIFEST:$name" } }
    # 테스트는 12단계/8개 필드 반복을 강제하지 않는다. 실제 명령·경로·안전성 계약을 검사한다.
}
function Assert-ContractReject([string]$Relative,[string]$Changed,[string]$Reason) {
    $path=Join-Path $copy $Relative;$original=[IO.File]::ReadAllBytes($path);$rejected=$false
    try {
        [IO.File]::WriteAllText($path,$Changed,[Text.UTF8Encoding]::new($false))
        try { Test-DocumentContract $copy } catch { $rejected=$true;Assert-Test ($_.Exception.Message.Contains($Reason)) "Negative control: $Reason" }
        if (-not $rejected) { throw "Negative control was not rejected: $Reason" }
    } finally { [IO.File]::WriteAllBytes($path,$original) }
}
Test-DocumentContract $copy
Assert-Test $true 'Standalone links, commands, chapters and safety contracts pass'
$readme=Get-Content -Raw -LiteralPath (Join-Path $copy 'README.md')
$guide=Get-Content -Raw -LiteralPath (Join-Path $copy 'docs/GETTING_STARTED.md')
$connect=Get-Content -Raw -LiteralPath (Join-Path $copy 'docs/CONNECT_AND_DATABASE.md')
$account=Get-Content -Raw -LiteralPath (Join-Path $copy 'docs/ACCOUNT_SETUP.md')
$tools=Get-Content -Raw -LiteralPath (Join-Path $copy 'docs/TOOLS_WINDOWS.md')
Assert-ContractReject 'README.md' ($readme+"`n[broken](docs/DOES_NOT_EXIST.md)") 'BROKEN_LINK'
Assert-ContractReject 'README.md' ($readme+"`n[outside](../../outside.md)") 'OUTSIDE_REPOSITORY'
Assert-ContractReject 'README.md' ($readme+"`n"+'Set-Location C:\workspace\project-cat') 'AUTHOR_PATH'
Assert-ContractReject 'docs/ACCOUNT_SETUP.md' ($account.Replace('-Step Region','-Step MissingStep')) 'SETUP_STEP'
Assert-ContractReject 'docs/GETTING_STARTED.md' ($guide+("`nextra"*131)) 'ENTRY_TOO_LONG'
Assert-ContractReject 'docs/CONNECT_AND_DATABASE.md' ($connect.Replace("'-F','none',",'')) 'SSH_AMBIENT_CONFIG'
Assert-ContractReject 'docs/CONNECT_AND_DATABASE.md' ($connect.Replace('"$sshKey.pub"','"$sshKey"')) 'SSH_PUBLIC_IDENTITY'
Assert-ContractReject 'docs/CONNECT_AND_DATABASE.md' ($connect.Replace('server-1과 server-2 두 서버 각각','첫 번째 서버만')) 'SSH_ALL_SERVERS'
Assert-ContractReject 'docs/CONNECT_AND_DATABASE.md' ($connect.Replace("'-o','BatchMode=yes',",'')) 'SSH_TUNNEL_CONTRACT'
Assert-ContractReject 'docs/CONNECT_AND_DATABASE.md' ($connect.Replace('TRUST CERTIFICATE','TRUST OMITTED')) 'TLS_APPROVAL'
Assert-ContractReject 'docs/TOOLS_WINDOWS.md' ($tools.Replace('oci-cli==3.94.0','oci-cli')) 'PINNED_INSTALL'
# 실제 로컬 버전 조회만 하며 설치/계정 조회는 하지 않는다.
$runtime=(Get-Process -Id $PID).Path
$prerequisiteJson=& $runtime -NoProfile -File (Join-Path $copy 'scripts/Test-Prerequisites.ps1') -AsJson
Assert-Test ($LASTEXITCODE -eq 0) 'Read-only prerequisite probe runs from standalone copy'
$prerequisites=$prerequisiteJson | ConvertFrom-Json -AsHashtable
Assert-Test ($prerequisites.kind -eq 'ACTUAL_LOCAL_READ_ONLY' -and $prerequisites.live_account -eq 'NOT_RUN' -and $prerequisites.installation_changes -eq 'NONE') 'Probe separates local execution and live NOT_RUN'
Assert-Test ($prerequisites.checks.Count -eq 5) 'Five tool checks are reported'
Test-DocumentContract $copy
@{kind='ACTUAL_LOCAL_STATIC_AND_NEGATIVE_CONTROLS_WHEN_EXECUTED';passed=$script:passed;standalone_path=$copy;live='NOT_RUN';prerequisites=$prerequisites} |
    ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $scratch 'portable-docs-results.json') -Encoding utf8
Write-Host "Portable docs: $script:passed checks passed; no cloud calls. Evidence: $scratch"
