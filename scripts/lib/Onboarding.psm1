Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

# 이 모듈은 로컬 입력만 다룬다. OCI/SQL/SSH/설치/State 변경은 호출하지 않는다.
function Copy-SetupObject {
    param($Value)
    return ($Value | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Assert-SetupPlainPath {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'SETUP_LINK: 링크/junction 경로는 자동 편집하지 않습니다. 실제 저장소 경로를 사용하세요.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Read-SetupJson {
    param([string]$Path)
    Assert-SetupPlainPath $Path
    $text = [IO.File]::ReadAllText($Path)
    # 중복 키는 편집 과정에서 조용히 유실될 수 있으므로 거부한다.
    $document = [Text.Json.JsonDocument]::Parse([string]$text, [Text.Json.JsonDocumentOptions]::new())
    try {
        function Test-UniqueJsonKeys($Element) {
            if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $Element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'SETUP_JSON: 중복되거나 대소문자만 다른 JSON 키가 있습니다.' }
                    Test-UniqueJsonKeys $property.Value
                }
            } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $Element.EnumerateArray()) { Test-UniqueJsonKeys $item }
            }
        }
        Test-UniqueJsonKeys $document.RootElement
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'SETUP_JSON: JSON 최상위는 object여야 합니다.' }
    } finally { $document.Dispose() }
    return ($text | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Open-SetupSession {
    param([string]$Root, [string]$Environment = 'dev')
    if ($Environment -cnotmatch '^[a-z][a-z0-9-]{0,30}$') { throw 'SETUP_ENV: 환경 이름은 소문자로 시작하는 소문자/숫자/하이픈 1~31자입니다.' }
    $rootPath = [IO.Path]::GetFullPath($Root)
    $directory = Join-Path $rootPath ".local/$Environment"
    Assert-SetupPlainPath $directory
    $data = @{}; $original = @{}; $hashes = @{}; $missing = @()
    foreach ($name in @('config', 'console-review', 'databases')) {
        $path = Join-Path $directory "$name.json"
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $data[$name] = Read-SetupJson $path
            $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        } else {
            $data[$name] = Read-SetupJson (Join-Path $rootPath "examples/$name.json.example")
            $hashes[$name] = $null
            $missing += $name
        }
        $original[$name] = Copy-SetupObject $data[$name]
    }
    return [pscustomobject]@{
        Root = $rootPath; Directory = $directory; Environment = $Environment
        Data = $data; Original = $original; Hashes = $hashes; Missing = $missing
    }
}

function Assert-SetupValue {
    param([string]$Kind, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\p{C}]|REPLACE|YOUR_USER|PRIVATE KEY' -or $Value.Length -gt 512) {
        throw '빈 값, 예시 placeholder, 여러 줄 또는 개인키 본문은 입력할 수 없습니다.'
    }
    $ok = switch ($Kind) {
        'Region' { $Value -cmatch '^[a-z]+-[a-z]+-[1-9][0-9]*$' }
        'Tenancy' { $Value -cmatch '^ocid1\.tenancy\.oc1\.\.[a-z0-9]{12,}$' }
        'Compartment' { $Value -cmatch '^ocid1\.compartment\.oc1\.\.[a-z0-9]{12,}$' }
        'Profile' { $Value -cmatch '^[A-Za-z0-9_-]{1,64}$' }
        'AccountStatus' { $Value.Length -le 120 }
        'DatabaseName' { $Value -cmatch '^[a-z][a-z0-9_]{0,63}$' }
        'DatabaseUser' { $Value -cmatch '^[a-z][a-z0-9_]{0,31}$' }
        'SshKey' {
            if (-not [IO.Path]::IsPathFullyQualified($Value) -or [IO.Path]::GetExtension($Value) -ne '.pub' -or -not (Test-Path -LiteralPath $Value -PathType Leaf)) { $false; break }
            $file = Get-Item -LiteralPath $Value
            if ($file.Length -gt 16384) { $false; break }
            $key = [IO.File]::ReadAllText($Value).Trim()
            if ($key -match 'PRIVATE KEY' -or $key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ([A-Za-z0-9+/=]+)(?: [^\r\n]*)?$') { $false; break }
            try { $bytes = [Convert]::FromBase64String($Matches[2]); $bytes.Length -ge 16 } catch { $false }
        }
        'SshCidr' {
            if ($Value -cnotmatch '^((?:0|[1-9][0-9]{0,2})\.){3}(?:0|[1-9][0-9]{0,2})/32$') { $false; break }
            $parts = @($Value.Split('/')[0].Split('.') | ForEach-Object { [int]$_ })
            if (@($parts | Where-Object { $_ -gt 255 }).Count) { $false; break }
            $a=$parts[0]; $b=$parts[1]; $c=$parts[2]
            -not ($a -in @(0,10,127) -or $a -ge 224 -or ($a -eq 100 -and $b -ge 64 -and $b -le 127) -or
                ($a -eq 169 -and $b -eq 254) -or ($a -eq 172 -and $b -ge 16 -and $b -le 31) -or
                ($a -eq 192 -and $b -eq 168) -or ($a -eq 192 -and $b -eq 0 -and $c -in @(0,2)) -or
                ($a -eq 198 -and $b -in @(18,19)) -or ($a -eq 198 -and $b -eq 51 -and $c -eq 100) -or
                ($a -eq 203 -and $b -eq 0 -and $c -eq 113))
        }
        default { throw "SETUP_KIND: 지원하지 않는 입력 종류: $Kind" }
    }
    if (-not $ok) { throw "입력 형식이 맞지 않습니다: $Kind. 화면의 안내와 예시를 확인하세요." }
}

function Reset-SetupReview {
    param($Review)
    # 새 입력이 이전 검토의 승인을 이어받지 않게 한다. true로 만드는 코드는 없다.
    foreach ($key in @($Review.Keys)) {
        if ($key -like '*_confirmed' -or $key -in @('policy_conflicts_resolved','limits_quotas_reviewed')) { $Review[$key] = $false }
    }
    $Review.reviewed_on = 'REPLACE_WITH_TODAY_YYYY-MM-DD'
    if ($Review.Contains('mysql_nsg_iam')) {
        $iam = $Review.mysql_nsg_iam
        foreach ($key in @($iam.Keys)) {
            if ($key -like '*_confirmed' -or $key -eq 'conflicts_resolved') { $iam[$key] = $false }
        }
        $iam.reviewed_on = 'REPLACE_WITH_TODAY_YYYY-MM-DD'
        $iam.policy_disposition = 'UNREVIEWED'
        $iam.unresolved_items = @(@($iam.unresolved_items) + 'Setup에서 입력을 변경했습니다. 대상과 정책을 다시 확인하세요.' | Select-Object -Unique)
    }
}

function Set-SetupInput {
    param($Session, [string]$Kind, [string]$Value)
    $Value = $Value.Trim()
    Assert-SetupValue $Kind $Value
    $config = $Session.Data.config; $review = $Session.Data['console-review']
    switch ($Kind) {
        'Region' { $config.region = $Value; $review.region = $Value; if ($review.Contains('mysql_nsg_iam')) { $review.mysql_nsg_iam.region = $Value } }
        'Tenancy' { $review.tenancy_ocid = $Value; if ($review.Contains('mysql_nsg_iam')) { $review.mysql_nsg_iam.tenancy_ocid = $Value } }
        'Compartment' {
            $config.compartment_ocid = $Value
            if ($review.Contains('mysql_nsg_iam')) { foreach ($key in @('db_compartment_ocid','nsg_compartment_ocid','subnet_compartment_ocid')) { $review.mysql_nsg_iam[$key] = $Value } }
        }
        'Profile' { $config.oci_profile = $Value }
        'AccountStatus' { $review.account_status = $Value }
        'SshKey' { $config.ssh_public_key_path = $Value.Replace('\','/') }
        'SshCidr' { $config.ssh_allowed_cidr = $Value }
        default { throw '이 입력은 Set-SetupInput의 단일 필드가 아닙니다.' }
    }
}

function Assert-SetupTarget {
    param($Session)
    $path = Join-Path $Session.Directory 'target.json'
    if (-not (Test-Path -LiteralPath $path)) {
        if ((Test-Path -LiteralPath (Join-Path $Session.Directory 'terraform.tfstate')) -or
            @(Get-ChildItem -LiteralPath $Session.Root -Filter '*.tfstate*' -File).Count) {
            throw 'SETUP_STATE: 대상 기록 없이 기존 State가 있습니다. 먼저 기존 운영/복구 절차를 확인하세요.'
        }
        return
    }
    $target = Read-SetupJson $path
    $pairs = @{
        environment = $Session.Environment
        tenancy_ocid = $Session.Data['console-review'].tenancy_ocid
        region = $Session.Data.config.region
        compartment_ocid = $Session.Data.config.compartment_ocid
    }
    foreach ($key in $pairs.Keys) {
        if ($pairs[$key] -cne $target[$key]) { throw "SETUP_TARGET: 이미 고정된 $key 변경은 금지합니다. target/State를 지우지 말고 별도 환경을 사용하세요." }
    }
}

function Save-SetupSession {
    param($Session, [switch]$InitializeMissing)
    $edited = @()
    foreach ($name in @('config','console-review','databases')) {
        if (($Session.Data[$name] | ConvertTo-Json -Depth 100 -Compress) -cne ($Session.Original[$name] | ConvertTo-Json -Depth 100 -Compress)) { $edited += $name }
    }
    if ($edited.Count -eq 0 -and (-not $InitializeMissing -or $Session.Missing.Count -eq 0)) {
        return [pscustomobject]@{ Changed = $false; Files = @(); Backup = $null }
    }
    Assert-SetupTarget $Session
    if ($edited.Count) { Reset-SetupReview $Session.Data['console-review'] }
    $names = @()
    foreach ($name in @('config','console-review','databases')) {
        if (($Session.Data[$name] | ConvertTo-Json -Depth 100 -Compress) -cne ($Session.Original[$name] | ConvertTo-Json -Depth 100 -Compress) -or ($InitializeMissing -and $name -in $Session.Missing)) { $names += $name }
    }
    Assert-SetupPlainPath $Session.Directory
    # 전체 문서의 읽은 시점 hash를 확인한다. 다른 편집기의 변경을 덮어쓰지 않는다.
    foreach ($name in $Session.Hashes.Keys) {
        $path = Join-Path $Session.Directory "$name.json"
        $actual = if (Test-Path -LiteralPath $path) { Assert-SetupPlainPath $path; (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        if ($actual -cne $Session.Hashes[$name]) { throw 'SETUP_CONFLICT: 입력 중 파일이 바뀌었습니다. 저장하지 않았습니다. 마법사를 다시 여세요.' }
    }
    Protect-EnvironmentDirectory $Session.Directory
    $backup = Join-Path $Session.Directory ('setup-backups/' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    Assert-SetupPlainPath $backup
    [void][IO.Directory]::CreateDirectory($backup)
    $pending = @{}; $committed = @(); $writtenHashes = @{}
    try {
        foreach ($name in $names) {
            $temp = Join-Path $Session.Directory ('.setup-' + [guid]::NewGuid().ToString('N') + '.tmp')
            $pending[$name] = $temp
            $json = ($Session.Data[$name] | ConvertTo-Json -Depth 100) + "`n"
            $stream = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            $writtenHashes[$name] = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
        }
        foreach ($name in $names) {
            $path = Join-Path $Session.Directory "$name.json"
            Assert-SetupPlainPath $path
            $actual = if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
            if ($actual -cne $Session.Hashes[$name]) { throw 'SETUP_CONFLICT: 저장 직전 다른 변경을 발견했습니다.' }
            if ($null -ne $Session.Hashes[$name]) {
                [IO.File]::Replace($pending[$name], $path, (Join-Path $backup "$name.json"))
            } else { [IO.File]::Move($pending[$name], $path) }
            $committed += $name
        }
    } catch {
        # 파일별 원자 교체. 잡을 수 있는 중간 실패는 되돌린다. 전원 중단 시에도 backup은 남는다.
        foreach ($name in $committed) {
            $path = Join-Path $Session.Directory "$name.json"
            $saved = Join-Path $backup "$name.json"
            $currentHash = if (Test-Path -LiteralPath $path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
            if ($currentHash -cne $writtenHashes[$name]) {
                Write-Warning "동시 편집된 $name.json은 되돌리지 않았습니다. backup과 실제 파일을 직접 대조하세요."
                continue
            }
            if (Test-Path -LiteralPath $saved) { [IO.File]::Copy($saved, $path, $true) }
            elseif ($null -eq $Session.Hashes[$name]) { [IO.File]::Delete($path) }
        }
        throw
    } finally {
        foreach ($temp in $pending.Values) { if (Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
    }
    return [pscustomobject]@{ Changed = $true; Files = $names; Backup = $backup }
}

function Read-SetupDiscovery {
    param($Session)
    $path = Join-Path $Session.Directory 'discovery.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'DISCOVERY_MISSING: 먼저 Preflight.ps1 -Environment <환경> -Discover를 실행하세요.' }
    $age = [datetime]::UtcNow - (Get-Item -LiteralPath $path).LastWriteTimeUtc
    if ($age.TotalHours -gt 24 -or $age.TotalMinutes -lt -2) { throw 'DISCOVERY_STALE: 조회 파일이 오래되었거나 시각이 잘못되었습니다. discovery를 다시 실행하세요.' }
    $discovery = Read-SetupJson $path
    if ($discovery.tenancy_ocid -cne $Session.Data['console-review'].tenancy_ocid -or $discovery.home_region -cne $Session.Data.config.region) {
        throw 'DISCOVERY_TARGET: 조회 결과와 입력한 계정/리전이 다릅니다. 실제 대상을 다시 확인하세요.'
    }
    Assert-SetupTarget $Session
    return $discovery
}

function Get-SetupLimitChoices {
    param($Config, $Discovery, [string]$Role)
    $known = @{ amd=@('compute','standard-e2-micro-core-count'); storage=@('block-storage','total-storage-gb'); backups=@('block-storage','backup-count'); autonomous=@('database','adb-free-count') }
    if ($Role -ne 'mysql' -and -not $known.ContainsKey($Role)) { throw '알 수 없는 한도 역할입니다.' }
    $choices = @($Discovery.limit_definitions | Where-Object {
        if ($Role -eq 'mysql') {
            $_.service_name -eq 'mysql' -and $_.name -match 'free' -and $_.name -notmatch 'heatwave|heat-wave|storage|backup' -and
            $_.description -match '(?i)(MySQL[. ]Free|Always Free.*DB [Ss]ystem|Free.*MySQL.*DB [Ss]ystem)'
        } else { $_.service_name -eq $known[$Role][0] -and $_.name -eq $known[$Role][1] }
    })
    # 미지원·모호한 정의는 추천하지 않는다. 최종 조회는 기존 Preflight가 다시 수행한다.
    return @($choices | Where-Object { $_.availability_supported -ceq $true -and $_.scope_type -in @('AD','REGION','GLOBAL') })
}

function New-SetupLimitRows {
    param($Config, $Discovery, [string]$Role, $Choice)
    $verified = @(Get-SetupLimitChoices $Config $Discovery $Role | Where-Object { $_.service_name -ceq $Choice.service_name -and $_.name -ceq $Choice.name -and $_.scope_type -ceq $Choice.scope_type })
    if ($verified.Count -ne 1) { throw 'LIMIT_AMBIGUOUS: 실제 조회된 유일한 한도 정의를 선택하세요.' }
    $ads = @($null)
    if ($Choice.scope_type -eq 'AD') {
        $ads = @(if ($Role -eq 'mysql') { $Config.mysql_availability_domain } else { $Config.servers.Values | ForEach-Object { $_.availability_domain } | Sort-Object -Unique })
        if ($ads.Count -eq 0 -or @($ads | Where-Object { $_ -notin $Discovery.availability_domains }).Count) { throw 'LIMIT_AD: Placement에서 서버/DB의 AD를 먼저 선택하세요.' }
    }
    $rows = @()
    foreach ($ad in $ads) {
        $old = @($Config.limit_checks | Where-Object { $_.role -eq $Role -and $_.service_name -eq $Choice.service_name -and $_.name -eq $Choice.name -and $_.availability_domain -eq $ad })
        $row = if ($old.Count -eq 1) { Copy-SetupObject $old[0] } else { @{} }
        $row.role=$Role; $row.service_name=$Choice.service_name; $row.name=$Choice.name; $row.availability_domain=$ad
        $rows += $row
    }
    return $rows
}

Export-ModuleMember -Function Copy-SetupObject,Assert-SetupPlainPath,Read-SetupJson,Open-SetupSession,Assert-SetupValue,Set-SetupInput,Save-SetupSession,Read-SetupDiscovery,Get-SetupLimitChoices,New-SetupLimitRows
