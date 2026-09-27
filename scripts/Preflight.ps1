#requires -Version 7.2
[CmdletBinding()]
param([string]$Environment='dev',[switch]$Discover)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Inventory.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Iam.psm1') -Force -DisableNameChecking
$context=Get-TaskContext $Environment
$settings=Read-JsonFile $context.Config
$identity=Get-ProfileIdentity $settings.oci_profile
Assert-Condition ($settings.region -match '^[a-z]+-[a-z]+-\d+$') 'config.json region에 실제 home region을 입력하세요.'
Assert-Condition ($settings.compartment_ocid -match '^ocid1\.compartment\.oc1\.\.' -and $settings.compartment_ocid -notmatch 'REPLACE') '전용 compartment OCID를 입력하세요.'
Protect-EnvironmentDirectory $context.Directory
Assert-EnvironmentTarget -Context $context -Tenancy $identity.Tenancy -Region $settings.region -Compartment $settings.compartment_ocid
Get-Command oci,terraform -ErrorAction Stop | Out-Null
$query={param($region,$arguments,$list) Invoke-OciJson -Identity $identity -Region $region -Arguments $arguments -List:$list}.GetNewClosure()
$inventoryPath=Join-Path $context.Directory 'inventory.json'
# A failed new check invalidates any previous PASS before making network calls.
Write-PrivateJson $inventoryPath @{status='INCOMPLETE';checked_at=[datetimeoffset]::UtcNow.ToString('o')}
$inventory=Get-AccountInventory -Identity $identity -Config $settings -Query $query
$limits=Get-LimitDiscovery -Identity $identity -Config $settings -Query $query
$iam=Get-MySqlNsgIamInspection -Identity $identity -Config $settings -Query $query
Write-PrivateJson (Join-Path $context.Directory 'iam-review.json') $iam
$candidates=@(& $query $settings.region @('compute','image','list','--compartment-id',$settings.compartment_ocid,'--operating-system','Canonical Ubuntu','--shape','VM.Standard.E2.1.Micro','--all') $true)
$discovery=@{tenancy_ocid=$identity.Tenancy;home_region=$inventory.home_region;availability_domains=$inventory.domains[$settings.region];image_candidates=@($candidates | Where-Object { -not $_['compartment-id'] -and $_['operating-system-version'] -in @('22.04','24.04') } | Select-Object -First 12 | ForEach-Object { @{id=$_.id;display_name=$_['display-name'];os_version=$_['operating-system-version'];size_in_mbs=$_['size-in-mbs']} });limit_definitions=$limits;resources=$inventory.resources}
Write-PrivateJson (Join-Path $context.Directory 'discovery.json') $discovery
$suggestions=Get-DiscoverySuggestions -Config $settings -Discovery $discovery
Write-PrivateJson (Join-Path $context.Directory 'discovery-suggestions.json') $suggestions
if ($Discover) {
    Write-Host "DISCOVERED (무료/IAM 권한 검증 PASS 아님): $($context.Directory)/discovery.json"
    Write-Host "AD 후보: $($discovery.availability_domains -join ', ') / Ubuntu image 후보: $($discovery.image_candidates.Count)개 / limit 정의: $($limits.Count)개"
    Write-Host "IAM 읽기 조회: $($iam.status). iam-review.json의 scope/정책과 실제 콘솔을 확인하세요."
    Write-Host 'discovery-suggestions.json에 정확한 JSON 경로와 후보를 기록했습니다. config.json/console-review.json은 자동 변경하지 않았습니다. null/미지원 한도는 추측하거나 0으로 입력하지 마세요.'
    exit 0
}
$review=Read-JsonFile $context.Review
Assert-ConsoleReview -Review $review -Config $settings -Tenancy $identity.Tenancy
$iam.readiness=Test-MySqlNsgIamReadiness -Inspection $iam -Review $review -Config $settings -Tenancy $identity.Tenancy
Write-PrivateJson (Join-Path $context.Directory 'iam-review.json') $iam
Assert-Condition $iam.readiness.ready ("MySQL NSG IAM REVIEW_REQUIRED: " + ($iam.readiness.issues -join ' '))
$policy=Get-OfficialPolicyEvidence
if ($settings.mysql_enabled) { $policy+=Get-MySqlNsgPolicyEvidence }
Assert-Condition ($settings.servers.Count -in @(1,2)) 'VM은 1~2개만 설정할 수 있습니다.'
Assert-Condition (Test-Path -LiteralPath $settings.ssh_public_key_path -PathType Leaf) 'SSH 공개키 .pub 경로가 필요합니다.'
$publicKey=Get-Content -Raw -LiteralPath $settings.ssh_public_key_path
Assert-Condition ($publicKey -match '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/=]+' -and $publicKey -notmatch 'PRIVATE KEY') '유효한 SSH 공개키만 입력하세요.'
Assert-Condition ($settings.ssh_allowed_cidr -match '^\d{1,3}(\.\d{1,3}){3}/32$' -and $settings.ssh_allowed_cidr -notmatch '^(0\.|10\.|127\.|192\.168\.|203\.0\.113\.|198\.51\.100\.|192\.0\.2\.)') '기본 경로 SSH는 실제 공인 IPv4 /32만 허용합니다.'
$verifiedImages=@()
foreach ($server in $settings.servers.Values) {
    Assert-Condition ($server.availability_domain -in $inventory.domains[$settings.region]) '서버 AD가 계정 home region의 AD가 아닙니다.'
    $image=& $query $settings.region @('compute','image','get','--image-id',$server.image_ocid) $false
    Assert-Condition (-not $image['compartment-id'] -and $image['operating-system'] -eq 'Canonical Ubuntu' -and $image['operating-system-version'] -in @('22.04','24.04') -and $image['lifecycle-state'] -eq 'AVAILABLE') '승인한 Canonical Ubuntu platform LTS image만 허용합니다. Marketplace/custom image는 무료 license 미확인으로 중단합니다.'
    Assert-Condition ($null -ne $image['size-in-mbs'] -and [double]$image['size-in-mbs'] -le [double]$server.boot_volume_size_in_gbs*1024) '이미지 최소 boot 크기 미확인/초과.'
    $shapes=@(& $query $settings.region @('compute','shape','list','--compartment-id',$settings.compartment_ocid,'--availability-domain',$server.availability_domain,'--image-id',$server.image_ocid,'--all') $true)
    Assert-Condition (@($shapes | Where-Object { $_.shape -eq 'VM.Standard.E2.1.Micro' }).Count -eq 1) 'AD/image가 AMD Micro와 호환되지 않습니다.'
    $verifiedImages+=$server.image_ocid
}
if ($settings.mysql_enabled) {
    Assert-Condition ($settings.mysql_availability_domain -in $inventory.domains[$settings.region]) 'MySQL AD가 계정 home region의 AD가 아닙니다.'
    $mysqlShapes=@(& $query $settings.region @('mysql','shape','list','--compartment-id',$settings.compartment_ocid,'--availability-domain',$settings.mysql_availability_domain,'--is-supported-for','DBSYSTEM','--all') $true)
    Assert-Condition (@($mysqlShapes | Where-Object { $_.name -eq 'MySQL.Free' }).Count -gt 0) '계정에서 MySQL.Free shape를 확인할 수 없습니다. 유료 대안 없이 중단합니다.'
    $mysqlVersions=@(& $query $settings.region @('mysql','version','list','--compartment-id',$settings.compartment_ocid,'--all') $true)
    Assert-Condition ($mysqlVersions.Count -gt 0) 'MySQL 제공 버전 미확인.'
    Write-PrivateJson (Join-Path $context.Directory 'mysql-versions.json') $mysqlVersions
}
$availability=Test-AccountLimits -Identity $identity -Config $settings -Discovery $limits -Query $query
$inventory.status='VERIFIED';$inventory.complete=$true;$inventory.tenancy_ocid=$identity.Tenancy;$inventory.region=$settings.region
$inventory.checked_at=[datetimeoffset]::UtcNow.ToString('o');$inventory.verified_images=@($verifiedImages | Sort-Object -Unique)
$inventory.limit_availability=$availability;$inventory.official_sources=$policy;$inventory.account_status=$review.account_status
$inventory.mysql_nsg_iam=$iam.readiness
$inventory.console_evidence='User attested today; CLI verified inventory/shape/home region/limits. Capacity and final billing are not guaranteed.'
Write-PrivateJson $inventoryPath $inventory
$tf=@{tenancy_ocid=$identity.Tenancy;home_region=$inventory.home_region;free_tier_only=$true}
foreach ($key in @('oci_profile','region','compartment_ocid','project_name','ssh_public_key_path','ssh_allowed_cidr','servers','mysql_enabled','mysql_availability_domain','mysql_admin_username','autonomous_databases','internal_tcp_rules')) { $tf[$key]=$settings[$key] }
Write-PrivateJson (Join-Path $context.Directory 'deployment.tfvars.json') $tf
Write-Host "PREFLIGHT PASS: tenancy=$($identity.Tenancy) region=$($settings.region) compartments=$($inventory.compartments.Count) regions=$($inventory.regions.Count)"
Write-Host '무료 근거: 실행일 공식 문서 + 계정 콘솔 확인 + 전체 리소스/한도 조회. 물리 capacity와 향후 청구는 별도 확인이 필요합니다.'
Write-Host "MySQL NSG IAM: $($iam.readiness.status); effective authorization NOT_PROVEN. 읽기 조회와 사람의 정책 검토는 실제 생성 권한/성공을 보장하지 않습니다."
