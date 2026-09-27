Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Assert-ConsoleReview {
    param([hashtable]$Review,[hashtable]$Config,[string]$Tenancy)
    Assert-Condition ($Review.reviewed_on -eq (Get-Date -Format 'yyyy-MM-dd')) '공식 문서/계정 콘솔을 실행일에 다시 확인하고 console-review.json을 갱신하세요.'
    Assert-Condition ($Review.tenancy_ocid -eq $Tenancy -and $Review.region -eq $Config.region) '콘솔 증거의 대상 tenancy/region이 다릅니다.'
    Assert-Condition ($Review.account_status -and $Review.account_status -notmatch 'REPLACE') '계정 상태가 확인되지 않았습니다.'
    $fields=@('official_policy_confirmed','policy_conflicts_resolved','tenancy_wide_inspect_confirmed','always_free_compute_confirmed','limits_quotas_reviewed')
    if ($Config.mysql_enabled) { $fields+=@('always_free_mysql_confirmed','mysql_backup_policy_confirmed') }
    if ($Config.autonomous_databases.Count -gt 0) { $fields+='always_free_autonomous_confirmed' }
    foreach ($field in $fields) { Assert-Condition ($Review[$field] -ceq $true) "console-review.json: $field 미확인. 무료 검증 중단." }
}

function Get-OfficialPolicyEvidence {
    $sources=@(
        @{name='always-free';url='https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm';markers=@('VM.Standard.E2.1.Micro','200','backup','home region')},
        @{name='mysql-free';url='https://docs.oracle.com/en-us/iaas/mysql-database/doc/creating-always-free-db-system.html';markers=@('MySQL.Free','50','backup')},
        @{name='mysql-features';url='https://docs.oracle.com/en-us/iaas/mysql-database/doc/features-mysql-heatwave-service.html';markers=@('Always Free','home region')},
        @{name='autonomous-free';url='https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-always-free.html';markers=@('Always Free','20','home region')}
    )
    $evidence=@()
    foreach ($source in $sources) {
        $response=Invoke-WebRequest -Uri $source.url -TimeoutSec 30 -MaximumRetryCount 1
        foreach ($marker in $source.markers) { Assert-Condition ($response.Content -match [regex]::Escape($marker)) "공식 문서 내용 변경/조회 실패: $($source.name). 수동 재검토가 필요합니다." }
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($response.Content)))
        $evidence+=@{url=$source.url;sha256=$hash;checked_at=[datetimeoffset]::UtcNow.ToString('o');verification='retrieved + markers; semantics attested in console-review.json'}
    }
    return ,$evidence
}

function Get-AccountInventory {
    param($Identity,[hashtable]$Config,[scriptblock]$Query)
    # Query signature: region, CLI arguments, is-list. Tests inject fixtures here only.
    $subscriptions=@(& $Query $Config.region @('iam','region-subscription','list','--tenancy-id',$Identity.Tenancy,'--all') $true)
    $homes=@($subscriptions | Where-Object { $_['is-home-region'] -eq $true })
    Assert-Condition ($homes.Count -eq 1 -and $homes[0]['region-name'] -eq $Config.region) '대상 리전이 확인된 home region과 다릅니다.'
    $regions=@($subscriptions | ForEach-Object { Assert-Condition ($_['status'] -eq 'READY') '준비되지 않은 구독 리전: 전체 조회 미완료.'; $_['region-name'] })
    Assert-Condition ($regions.Count -gt 0) '구독 리전 목록이 비어 있습니다.'
    $compartmentRows=@(& $Query $Config.region @('iam','compartment','list','--compartment-id',$Identity.Tenancy,'--compartment-id-in-subtree','true','--access-level','ANY','--all') $true)
    $compartments=@($Identity.Tenancy)+@($compartmentRows | Where-Object { $_['lifecycle-state'] -ne 'DELETED' } | ForEach-Object { $_.id })
    Assert-Condition ($Config.compartment_ocid -in $compartments -and $Config.compartment_ocid -ne $Identity.Tenancy) '검증된 전용 compartment가 필요합니다(루트 tenancy 금지).'
    $resources=[Collections.Generic.List[object]]::new(); $domains=@{}
    foreach ($region in $regions) {
        $ads=@(& $Query $region @('iam','availability-domain','list','--compartment-id',$Identity.Tenancy,'--all') $true)
        Assert-Condition ($ads.Count -gt 0) 'AD 목록 누락.'
        $domains[$region]=@($ads | ForEach-Object { $_.name })
        foreach ($compartment in $compartments) {
            foreach ($spec in @(
                @{kind='instance';args=@('compute','instance','list')},
                @{kind='block';args=@('bv','volume','list')},
                @{kind='boot_backup';args=@('bv','boot-volume-backup','list')},
                @{kind='block_backup';args=@('bv','backup','list')},
                @{kind='mysql';args=@('mysql','db-system','list')},
                @{kind='mysql_backup';args=@('mysql','backup','list')},
                @{kind='autonomous';args=@('db','autonomous-database','list')}
            )) {
                $items=@(& $Query $region ($spec.args+@('--compartment-id',$compartment,'--all')) $true)
                foreach ($item in $items) {
                    if ($item['lifecycle-state'] -in @('TERMINATED','DELETED')) { continue }
                    Assert-Condition ($item.id -and $item['lifecycle-state']) '리소스 ID/상태 누락.'
                    $record=@{kind=$spec.kind;id=$item.id;region=$region;compartment_id=$compartment;state=$item['lifecycle-state']}
                    switch ($spec.kind) {
                        'instance' { Assert-Condition ([bool]$item.shape) 'Compute shape 누락.'; $record.shape=$item.shape }
                        'block' { Assert-Condition ($null -ne $item['size-in-gbs'] -and $null -ne $item['vpus-per-gb']) 'Block 용량/성능 누락.'; $record.size_gb=$item['size-in-gbs'];$record.vpus_per_gb=$item['vpus-per-gb'] }
                        'mysql' {
                            Assert-Condition ([bool]$item['shape-name']) 'MySQL shape 누락.'; $record.shape=$item['shape-name']
                            if ($record.shape -eq 'MySQL.Free') {
                                $detail=& $Query $region @('mysql','db-system','get','--db-system-id',$item.id) $false
                                Assert-Condition ($detail['data-storage-size-in-gbs'] -eq 50 -and $detail['is-highly-available'] -eq $false) '기존 MySQL 무료 고정 설정 미확인.'
                                Assert-Condition ($detail['backup-policy']['is-enabled'] -eq $true -and $detail['backup-policy']['retention-in-days'] -eq 1 -and $detail['backup-policy']['pitr-policy']['is-enabled'] -eq $false) '기존 MySQL 백업/PITR 무료 조건 미확인.'
                                $record.version=$detail['mysql-version']
                            }
                        }
                        'mysql_backup' {
                            Assert-Condition ($item['shape-name'] -and $null -ne $item['backup-size-in-gbs']) 'MySQL backup shape/용량 누락.'
                            $record.shape=$item['shape-name'];$record.size_gb=$item['backup-size-in-gbs']
                        }
                        'autonomous' { Assert-Condition ($item['is-free-tier'] -is [bool]) 'Autonomous 무료 분류 미확인.'; $record.is_free_tier=$item['is-free-tier'] }
                    }
                    $resources.Add($record)
                }
            }
            foreach ($ad in $domains[$region]) {
                $boots=@(& $Query $region @('bv','boot-volume','list','--compartment-id',$compartment,'--availability-domain',$ad,'--all') $true)
                foreach ($boot in $boots) {
                    if ($boot['lifecycle-state'] -in @('TERMINATED','DELETED')) { continue }
                    Assert-Condition ($boot.id -and $null -ne $boot['size-in-gbs'] -and $null -ne $boot['vpus-per-gb']) 'Boot volume ID/용량/성능 누락.'
                    $resources.Add(@{kind='boot';id=$boot.id;region=$region;compartment_id=$compartment;state=$boot['lifecycle-state'];size_gb=$boot['size-in-gbs'];vpus_per_gb=$boot['vpus-per-gb']})
                }
            }
        }
    }
    $mysqlBackupGb=0.0
    foreach ($backup in @($resources | Where-Object { $_.kind -eq 'mysql_backup' -and $_.shape -eq 'MySQL.Free' })) { $mysqlBackupGb += [double]$backup.size_gb }
    Assert-Condition ($mysqlBackupGb -le 50) '무료 MySQL backup 저장소 합계 > 50GiB.'
    @{resources=@($resources.ToArray());regions=$regions;compartments=$compartments;domains=$domains;home_region=$homes[0]['region-name'];mysql_backup_gb=$mysqlBackupGb}
}

function Get-LimitDiscovery {
    param($Identity,[hashtable]$Config,[scriptblock]$Query)
    $result=@()
    foreach ($service in @('compute','block-storage','mysql','database')) {
        $rows=@(& $Query $Config.region @('limits','definition','list','--compartment-id',$Identity.Tenancy,'--service-name',$service,'--all') $true)
        foreach ($row in $rows) { $result+=@{service_name=$service;name=$row.name;description=$row.description;scope_type=$row['scope-type'];availability_supported=$row['is-resource-availability-supported']} }
    }
    return ,$result
}

function Test-AccountLimits {
    param($Identity,[hashtable]$Config,$Discovery,[scriptblock]$Query)
    $roles=@('amd','storage','backups'); if ($Config.mysql_enabled) { $roles+='mysql' }; if ($Config.autonomous_databases.Count -gt 0) { $roles+='autonomous' }
    $results=@()
    foreach ($role in $roles) {
        $checks=@($Config.limit_checks | Where-Object { $_.role -eq $role })
        Assert-Condition ($checks.Count -gt 0) "limit_checks에 $role 한도 매핑이 없습니다. discovery.json의 공식 계정 정의를 보고 입력하세요."
        foreach ($check in $checks) {
            $definition=@($Discovery | Where-Object { $_.service_name -eq $check.service_name -and $_.name -eq $check.name })
            $expected=@{amd=@('compute','standard-e2-micro-core-count');storage=@('block-storage','total-storage-gb');backups=@('block-storage','backup-count');autonomous=@('database','adb-free-count')}
            if ($role -eq 'mysql') {
                Assert-Condition ($check.service_name -eq 'mysql' -and $check.name -match 'free' -and $check.name -notmatch 'heatwave|heat-wave|storage|backup' -and $definition.Count -eq 1 -and $definition[0].description -match '(?i)(MySQL[. ]Free|Always Free.*DB [Ss]ystem|Free.*MySQL.*DB [Ss]ystem)') '계정 definition의 MySQL.Free DB System 수량 한도만 매핑하세요. 모호한 이름/설명은 중단합니다.'
            }
            else { Assert-Condition ($check.service_name -eq $expected[$role][0] -and $check.name -eq $expected[$role][1]) "$role 에 다른 서비스 한도를 매핑할 수 없습니다." }
            Assert-Condition ($definition.Count -eq 1 -and $definition[0].availability_supported -eq $true) "지원하지 않는 limit availability: $role. 무료 여부 미확인으로 중단합니다."
            $arguments=@('limits','resource-availability','get','--compartment-id',$Config.compartment_ocid,'--service-name',$check.service_name,'--limit-name',$check.name)
            if ($definition[0].scope_type -eq 'AD') { Assert-Condition ([bool]$check.availability_domain) 'AD scope 한도에 AD 필요.'; $arguments+=@('--availability-domain',$check.availability_domain) }
            $value=& $Query $Config.region $arguments $false
            Assert-Condition ($null -ne $value.used -and $null -ne $value.available -and $value.available -ge 0) '한도 usage/availability가 비어 있거나 미확인입니다.'
            $results+=@{role=$role;service_name=$check.service_name;name=$check.name;scope_type=$definition[0].scope_type;availability_domain=$check.availability_domain;used=$value.used;available=$value.available}
        }
    }
    return ,$results
}

Export-ModuleMember -Function Assert-ConsoleReview,Get-OfficialPolicyEvidence,Get-AccountInventory,Get-LimitDiscovery,Test-AccountLimits
