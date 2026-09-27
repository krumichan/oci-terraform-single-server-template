#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Environment = 'dev',
    [ValidateSet('Menu','Region','Tenancy','AccountStatus','Compartment','Profile','SshKey','SshCidr','Placement','Limits','Databases','Status')]
    [string]$Step = 'Menu'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Onboarding.psm1') -Force -DisableNameChecking
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Read-SetupAnswer([string]$Prompt) {
    if ([Console]::IsInputRedirected) {
        Write-Host ($Prompt + ': ') -NoNewline
        $answer = [Console]::ReadLine()
    } else { $answer = Read-Host $Prompt }
    if ($null -eq $answer -or $answer.Trim() -ceq 'Q' -or $answer.Trim() -ceq 'q') { throw 'SETUP_CANCELLED' }
    return $answer.Trim()
}
function Show-SafeValue($Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '(미입력)' }
    $safe = [regex]::Replace([string]$Value, '[\p{C}]', '?')
    if ($safe.Length -gt 180) { return $safe.Substring(0,180) + '…' }
    return $safe
}
function Ask-SetupValue([string]$Title,[string]$Kind,[string]$Current,[string[]]$Instructions) {
    Write-Host "`n=== $Title ==="
    foreach ($line in $Instructions) { Write-Host $line }
    Write-Host ('현재 값: ' + (Show-SafeValue $Current))
    Write-Host '값을 붙여넣으세요. Enter = 현재 값 유지 / Q = 이 단계 취소'
    while ($true) {
        $answer = Read-SetupAnswer '입력'
        if ($answer -eq '') { $answer = $Current }
        try { Assert-SetupValue $Kind $answer; return $answer }
        catch { Write-Host $_.Exception.Message; Write-Host '유효한 값이 아직 없으면 Q로 나간 뒤 준비하고 다시 실행하세요.' }
    }
}
function Ask-SetupChoice([string]$Title,[object[]]$Choices,[string[]]$Labels,[string]$Current) {
    if ($Choices.Count -eq 0 -or $Choices.Count -ne $Labels.Count) { throw "후보가 없거나 불완전합니다: $Title. 임의 값을 넣지 말고 discovery/콘솔을 확인하세요." }
    Write-Host "`n=== $Title ==="
    Write-Host ('현재 값: ' + (Show-SafeValue $Current))
    for ($i=0; $i -lt $Choices.Count; $i++) { Write-Host ('{0}. {1}' -f ($i+1),(Show-SafeValue $Labels[$i])) }
    while ($true) {
        $answer = Read-SetupAnswer '번호 선택 (Q=취소)'
        $index = 0
        if ([int]::TryParse($answer,[ref]$index) -and $index -ge 1 -and $index -le $Choices.Count) { return $Choices[$index-1] }
        Write-Host '표시된 번호 하나를 입력하세요. 후보가 하나여도 직접 선택합니다.'
    }
}
function Confirm-SetupSave($Session) {
    Write-Host "`n로컬 설정만 저장합니다. 서버/DB/IAM은 만들지 않습니다."
    Write-Host '값이 변경되면 기존 무료/IAM 검토 확인은 미확인으로 되돌립니다. 새 Preflight/Plan이 필요합니다.'
    Write-Host '다른 설정은 보존하며 기존 파일의 원본은 .local/<환경>/setup-backups에 남깁니다.'
    if ((Read-SetupAnswer '저장하려면 SAVE 입력 (다른 입력=저장 안 함)') -cne 'SAVE') { Write-Host '저장하지 않았습니다.'; return }
    $result = Save-SetupSession -Session $Session -InitializeMissing
    if ($result.Changed) {
        foreach ($name in $result.Files) { Write-Host ('저장: ' + (Join-Path $Session.Directory "$name.json")) }
        Write-Host ('백업: ' + $result.Backup)
    } else { Write-Host '기존 값과 같아서 파일을 변경하지 않았습니다.' }
    Write-Host '입력 형식 확인일 뿐입니다. 무료 자격/실제 권한/접속 성공은 아직 확인하지 않았습니다.'
}
function Show-SetupStatus($Session) {
    Write-Host "`n환경: $Environment / 로컬 입력 상태 (실계정 검증 아님)"
    $rows = @(
        @('Region','config','region'), @('Tenancy','console-review','tenancy_ocid'), @('AccountStatus','console-review','account_status'),
        @('Compartment','config','compartment_ocid'), @('Profile','config','oci_profile'), @('SshKey','config','ssh_public_key_path'), @('SshCidr','config','ssh_allowed_cidr')
    )
    foreach ($row in $rows) {
        $value = [string]$Session.Data[$row[1]][$row[2]]
        $status = try { Assert-SetupValue $row[0] $value; '입력됨 (형식만 확인)' } catch { '미입력/확인 필요' }
        Write-Host ('{0}: {1}' -f $row[0],$status)
    }
    foreach ($name in $Session.Missing) { Write-Host "아직 생성되지 않은 파일: $name.json" }
    Write-Host 'Status는 파일, ACL, 설정, 네트워크를 변경하지 않습니다. 부족한 단계만 다시 실행하세요.'
}
function Invoke-SetupStep([string]$Selected) {
    $session = Open-SetupSession -Root $root -Environment $Environment
    $config = $session.Data.config; $review = $session.Data['console-review']
    switch ($Selected) {
        'Status' { Show-SetupStatus $session; return }
        'Region' {
            $value = Ask-SetupValue 'Home Region 코드 하나 입력' Region $config.region @(
                '1. OCI 콘솔 위쪽 Region(리전 이름)을 누릅니다.',
                '2. Manage Regions(리전 관리)를 누릅니다.',
                '3. Home 표시가 있는 행의 Region Identifier를 복사합니다.',
                '   예: ap-tokyo-1. 예시는 선택 권장이 아닙니다. 본인 Home 값을 사용하세요.',
                '저장 위치: config.json → region / console-review.json → region')
            Set-SetupInput $session Region $value
        }
        'Tenancy' {
            $value = Ask-SetupValue 'Tenancy OCID 하나 입력' Tenancy $review.tenancy_ocid @(
                '1. OCI 오른쪽 위 Profile(사람 아이콘)을 누릅니다.',
                '2. Tenancy: <계정 이름> 또는 Tenancy details를 엽니다.',
                '3. OCID 옆 Copy를 누릅니다. User OCID와는 다릅니다.',
                '저장 위치: console-review.json → tenancy_ocid')
            Set-SetupInput $session Tenancy $value
        }
        'AccountStatus' {
            $value = Ask-SetupValue '현재 계정 상태 문구 입력' AccountStatus $review.account_status @(
                '1. OCI 메뉴 → Billing & Cost Management → Upgrade and Manage Payment를 엽니다.',
                '2. 표시된 Free Trial/Free Tier/Pay As You Go 등의 계정 상태 문구를 읽습니다.',
                '3. 상태 문구를 그대로 입력합니다. Upgrade 버튼은 누르지 않습니다.',
                '메뉴가 다르면 docs/ACCOUNT_SETUP.md의 계정 상태 절차를 확인하세요.',
                '저장 위치: console-review.json → account_status. 무료 통과로 처리하지 않습니다.')
            Set-SetupInput $session AccountStatus $value
        }
        'Compartment' {
            $value = Ask-SetupValue '전용 Compartment OCID 입력' Compartment $config.compartment_ocid @(
                '1. OCI 메뉴 → Identity & Security → Compartments를 엽니다.',
                '2. 사용할 전용 compartment 이름을 누릅니다. 없으면 ACCOUNT_SETUP.md의 생성 절차를 먼저 수행하세요.',
                '3. 상세의 OCID 옆 Copy를 누릅니다. root tenancy OCID는 사용하지 않습니다.',
                '저장 위치: config.json → compartment_ocid')
            Set-SetupInput $session Compartment $value
        }
        'Profile' {
            $value = Ask-SetupValue '로컬 OCI profile 이름 입력' Profile $config.oci_profile @(
                '1. docs/ACCOUNT_SETUP.md에서 API 키 등록과 .oci/config 작성까지 끝냅니다.',
                '2. .oci/config의 [TRANSLACAT]처럼 대괄호 안의 이름만 입력합니다.',
                '기본 예시: TRANSLACAT. 개인키/암호를 여기에 붙이지 마세요.',
                '저장 위치: config.json → oci_profile. 인증 파일 자체는 변경하지 않습니다.')
            Set-SetupInput $session Profile $value
        }
        'SshKey' {
            $value = Ask-SetupValue 'SSH 공개키 파일 경로 입력' SshKey $config.ssh_public_key_path @(
                '1. docs/SSH_AND_DISCOVERY.md에서 SSH 키를 만들거나 기존 키를 확인합니다.',
                '2. .pub로 끝나는 공개키의 전체 경로를 입력합니다. 따옴표는 붙이지 않습니다.',
                ('예시 경로: ' + (Join-Path $HOME '.ssh/translacat_oci.pub')),
                '저장 위치: config.json → ssh_public_key_path. 파일 내용을 변경하지 않습니다.')
            Set-SetupInput $session SshKey $value
        }
        'SshCidr' {
            $value = Ask-SetupValue 'SSH를 허용할 공인 IPv4 /32 입력' SshCidr $config.ssh_allowed_cidr @(
                '1. docs/SSH_AND_DISCOVERY.md의 공인 IP 확인을 수행합니다.',
                '2. 확인한 공인 IPv4 끝에 /32를 붙여 입력합니다.',
                '집 안의 192.168... 주소 또는 예시 203.0.113.10은 입력하지 않습니다.',
                '저장 위치: config.json → ssh_allowed_cidr. 실제 IP/방화벽은 별도 검증합니다.')
            Set-SetupInput $session SshCidr $value
        }
        'Placement' {
            $discovery = Read-SetupDiscovery $session
            foreach ($name in @($config.servers.Keys | Sort-Object)) {
                $server = $config.servers[$name]
                $ad = Ask-SetupChoice "$name 서버의 AD(배치 위치)" @($discovery.availability_domains) @($discovery.availability_domains) $server.availability_domain
                $images = @($discovery.image_candidates | Where-Object { $_.os_version -in @('22.04','24.04') -and $null -ne $_.size_in_mbs -and [double]$_.size_in_mbs -le [double]$server.boot_volume_size_in_gbs*1024 })
                $labels = @($images | ForEach-Object { "Ubuntu $($_.os_version) | $($_.display_name) | $($_.id)" })
                $image = Ask-SetupChoice "$name 서버의 Ubuntu 이미지" $images $labels $server.image_ocid
                $server.availability_domain = [string]$ad
                $server.image_ocid = $image.id
                Write-Host "선택: servers.$name → $ad / $($image.id)"
            }
            if ($config.mysql_enabled) {
                Write-Host 'DB는 콘솔에서 MySQL.Free가 제공되는지 확인한 AD만 선택하세요.'
                $config.mysql_availability_domain = [string](Ask-SetupChoice 'MySQL AD' @($discovery.availability_domains) @($discovery.availability_domains) $config.mysql_availability_domain)
            }
            Write-Host '후보 선택은 무료/가용 용량/호환성 검증이 아닙니다. 다음 Preflight가 다시 검사합니다.'
        }
        'Limits' {
            $discovery = Read-SetupDiscovery $session
            $roles = @('amd','storage','backups')
            if ($config.mysql_enabled) { $roles += 'mysql' }
            if ($config.autonomous_databases.Count -gt 0) { $roles += 'autonomous' }
            foreach ($role in $roles) {
                $choices = @(Get-SetupLimitChoices $config $discovery $role)
                $labels = @($choices | ForEach-Object { "$($_.service_name) | $($_.name) | $($_.scope_type) | $($_.description)" })
                $choice = Ask-SetupChoice "$role 한도 정의 (콘솔과 일치한 것 선택)" $choices $labels '기존 설정은 저장 전까지 유지'
                $rows = @(New-SetupLimitRows $config $discovery $role $choice)
                $config.limit_checks = @(@($config.limit_checks | Where-Object { $_.role -ne $role }) + $rows)
                foreach ($row in $rows) { Write-Host "선택: $role / $($row.name) / AD=$($row.availability_domain)" }
            }
            Write-Host '숫자 usage/available은 입력하거나 만들지 않습니다. 실제 잔여량은 Preflight가 조회합니다.'
        }
        'Databases' {
            $dbs = @($session.Data.databases.databases)
            if ($dbs.Count -eq 0) { Write-Host '등록된 DB 정의가 없습니다. 기존 빈 설정을 유지합니다.'; return }
            foreach ($db in $dbs) {
                $db.name = Ask-SetupValue '논리 DB 이름 (비밀번호 아님)' DatabaseName $db.name @('기존 행의 이름만 편집합니다. 물리 DB나 테이블은 만들지 않습니다.')
                $db.username = Ask-SetupValue '이 DB 전용 실행 계정 이름' DatabaseUser $db.username @('비밀번호는 나중에 Bootstrap의 secure prompt에서 입력합니다. host와 다른 속성은 유지합니다.')
            }
            if (@($dbs.name | Sort-Object -Unique).Count -ne $dbs.Count -or @($dbs | ForEach-Object { "$($_.username)@$($_.host)" } | Sort-Object -Unique).Count -ne $dbs.Count) { throw 'DB 이름/계정이 중복됩니다. 저장하지 않았습니다.' }
        }
        default { throw '지원하지 않는 단계입니다.' }
    }
    Confirm-SetupSave $session
}

try {
    Write-Host 'TranslaCat OCI 로컬 설정 마법사'
    Write-Host 'OCI 호출/프로그램 설치/PATH/서비스/키/State 변경 없음. IAM/무료 확인은 자동 승인하지 않습니다.'
    if ($Step -ne 'Menu') { Invoke-SetupStep $Step; return }
    $steps = @('Region','Tenancy','AccountStatus','Compartment','Profile','SshKey','SshCidr','Placement','Limits','Databases','Status')
    while ($true) {
        Write-Host "`n필요한 항목 하나를 선택하세요. 저장 후 이 메뉴로 돌아옵니다."
        $labels = @('Home Region','Tenancy OCID','계정 상태','Compartment OCID','API profile 이름','SSH 공개키 경로','SSH 허용 공인 IP','discovery → AD/이미지 선택','discovery → 한도 선택','논리 DB/계정 이름','입력 상태 확인')
        for ($i=0; $i -lt $steps.Count; $i++) { Write-Host ('{0}. {1}' -f ($i+1),$labels[$i]) }
        $answer = Read-SetupAnswer '번호 (Q=종료)'
        $index=0
        if (-not [int]::TryParse($answer,[ref]$index) -or $index -lt 1 -or $index -gt $steps.Count) { Write-Host '표시된 번호를 입력하세요.'; continue }
        try { Invoke-SetupStep $steps[$index-1] }
        catch { if ($_.Exception.Message -eq 'SETUP_CANCELLED') { Write-Host '현재 단계는 저장하지 않았습니다.' } else { throw } }
    }
} catch {
    if ($_.Exception.Message -eq 'SETUP_CANCELLED') { Write-Host '종료했습니다. 아직 저장하지 않은 입력은 반영하지 않았습니다.' }
    else { Write-Error $_.Exception.Message }
}
