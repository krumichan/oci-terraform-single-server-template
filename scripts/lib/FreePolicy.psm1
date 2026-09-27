Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Require-Policy {
    param([bool]$Condition,[string]$Reason)
    if (-not $Condition) { throw "FREE_POLICY_BLOCKED: $Reason" }
}
function Require-Known {
    param($Object,[string]$Key)
    Require-Policy ($null -ne $Object -and $Object.ContainsKey($Key) -and $null -ne $Object[$Key]) "필수 값 $Key 미확인/unknown."
    return $Object[$Key]
}
function Test-UnknownTree {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) { foreach ($v in $Value.Values) { if (Test-UnknownTree $v) { return $true } } }
    elseif ($Value -is [array]) { foreach ($v in $Value) { if (Test-UnknownTree $v) { return $true } } }
    return $false
}
function Require-EmptyOptional {
    param($Values,$Unknown,[string]$Key)
    Require-Policy ($Values.ContainsKey($Key) -and $null -ne $Values[$Key] -and @($Values[$Key]).Count -eq 0) "추가 기능 $Key 는 비어 있어야 합니다."
    Require-Policy (-not ($null -ne $Unknown -and $Unknown.ContainsKey($Key) -and (Test-UnknownTree $Unknown[$Key]))) "추가 기능 $Key unknown 금지."
}
function Get-SafeReviewValues {
    param($Value)
    if ($null -eq $Value) { return $null }
    $safe=@{}
    foreach ($key in @('shape','shape_name','availability_domain','display_name','cidr_block','cidr_blocks','prohibit_public_ip_on_vnic','direction','protocol','source','source_type','destination','destination_type','tcp_options','udp_options','data_storage_size_in_gb','is_highly_available','database_management','backup_policy','deletion_policy','read_endpoint','is_free_tier','cpu_core_count','db_name','is_mtls_connection_required','whitelisted_ips')) {
        if ($Value.ContainsKey($key)) { $safe[$key]=$Value[$key] }
    }
    if ($Value.ContainsKey('source_details')) { $safe.source_details=@($Value.source_details | ForEach-Object { @{image=$_.source_id;boot_gb=$_.boot_volume_size_in_gbs;vpus=$_.boot_volume_vpus_per_gb} }) }
    if ($Value.ContainsKey('metadata') -and $null -ne $Value.metadata) {
        $safe.metadata_sha256=@{}
        foreach ($key in $Value.metadata.Keys) { $safe.metadata_sha256[$key]=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$Value.metadata[$key]))) }
    }
    return $safe
}

function Test-FreePlan {
    [CmdletBinding()]
    param([hashtable]$Plan,[hashtable]$Inventory,[hashtable]$Config)
    Require-Policy ($Inventory.status -eq 'VERIFIED' -and $Inventory.complete -eq $true) '계정/공식정책/전체 compartment/페이지 검증 미완료.'
    Require-Policy ($Inventory.region -eq $Inventory.home_region -and $Config.region -eq $Inventory.region) 'home region 불일치.'
    Require-Policy (([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($Inventory.checked_at)).TotalMinutes -le 30) '사용량 증거가 30분 이상 경과했습니다.'
    Require-Policy (([datetimeoffset]::UtcNow - [datetimeoffset]::Parse($Inventory.checked_at)).TotalMinutes -ge -2) '사용량 증거가 미래 시각입니다.'
    Require-Policy ($Plan.ContainsKey('resource_changes')) 'resource_changes 누락.'
    $allowed = @('oci_core_vcn','oci_core_internet_gateway','oci_core_route_table','oci_core_security_list','oci_core_subnet','oci_core_network_security_group','oci_core_network_security_group_security_rule','oci_core_instance','oci_mysql_mysql_db_system','oci_database_autonomous_database')
    $resources = @($Inventory.resources)
    $ids = @{}; foreach ($r in $resources) { $id=Require-Known $r 'id'; Require-Policy (-not $ids.ContainsKey($id)) '중복 inventory ID.'; $ids[$id]=$r }
    $amd = @($resources | Where-Object { $_.kind -eq 'instance' -and $_.shape -eq 'VM.Standard.E2.1.Micro' }).Count
    $mysql = @($resources | Where-Object { $_.kind -eq 'mysql' -and $_.shape -eq 'MySQL.Free' }).Count
    $adb = @($resources | Where-Object { $_.kind -eq 'autonomous' -and $_.is_free_tier -eq $true }).Count
    $storage = 0.0; foreach ($r in @($resources | Where-Object { $_.kind -in @('boot','block') })) { $storage += [double](Require-Known $r 'size_gb'); Require-Policy ($r.vpus_per_gb -in @(0,10)) '기존 boot/block volume 성능의 무료 여부 미확인.' }
    $backups = @($resources | Where-Object { $_.kind -in @('boot_backup','block_backup') }).Count
    $newAmd=0; $newMysql=0; $newAdb=0; $newStorage=0.0; $deletions=@(); $summary=@(); $increments=@()
    foreach ($rc in $Plan.resource_changes) {
        if ($rc.mode -eq 'data') { continue }
        Require-Policy ($rc.type -in $allowed) "허용하지 않은 리소스 종류: $($rc.type)"
        $change = $rc.change; $actions=@($change.actions)
        if ('delete' -in $actions) { $deletions += $rc.address }
        if ($actions.Count -eq 1 -and $actions[0] -eq 'delete') { continue }
        $v = $change.after; $u=$change.after_unknown
        Require-Policy ($null -ne $v) 'after 값 누락.'
        if ($v.ContainsKey('compartment_id')) { Require-Policy ($v.compartment_id -eq $Config.compartment_ocid) '대상 compartment 이탈/unknown.' }
        $isNew = 'create' -in $actions
        $before = $change.before
        if (-not $isNew -and $rc.type -in @('oci_core_instance','oci_mysql_mysql_db_system','oci_database_autonomous_database')) {
            Require-Policy ($null -ne $before -and $ids.ContainsKey($before.id)) 'State의 기존 자원이 전체 계정 inventory에서 누락되었습니다.'
            $existing=$ids[$before.id]
            switch ($rc.type) {
                'oci_core_instance' { Require-Policy ($existing.kind -eq 'instance' -and $existing.shape -eq 'VM.Standard.E2.1.Micro') '기존 유료/다른 Compute를 무료형으로 전환하지 않습니다.' }
                'oci_mysql_mysql_db_system' { Require-Policy ($existing.kind -eq 'mysql' -and $existing.shape -eq 'MySQL.Free') '기존 유료/다른 MySQL 전환 금지.' }
                'oci_database_autonomous_database' { Require-Policy ($existing.kind -eq 'autonomous' -and $existing.is_free_tier -eq $true) '기존 유료 Autonomous 전환 금지.' }
            }
        }
        switch ($rc.type) {
            'oci_core_instance' {
                foreach ($key in @('licensing_configs','launch_volume_attachments','shape_config')) { Require-EmptyOptional $v $u $key }
                Require-Policy ((Require-Known $v 'is_ai_enterprise_enabled') -eq $false) 'AI Enterprise 유료 기능 금지.'
                Require-Policy ((Require-Known $v 'shape') -eq 'VM.Standard.E2.1.Micro') '유료/ARM Compute shape 금지.'
                $source=@(Require-Known $v 'source_details'); Require-Policy ($source.Count -eq 1) 'image source 누락.'
                $gb=[double](Require-Known $source[0] 'boot_volume_size_in_gbs')
                Require-Policy ($gb -ge 50 -and $gb -le 200) 'boot volume 크기 미확인/범위 초과.'
                Require-Policy ((Require-Known $source[0] 'boot_volume_vpus_per_gb') -in @(0,10)) 'boot volume 성능 무료범위 초과.'
                Require-Policy ($source[0].source_type -eq 'image' -and $source[0].source_id -in @($Inventory.verified_images)) '검증되지 않은 image (유료 license/architecture 포함).'
                if ($isNew) { $newAmd++; $newStorage+=$gb; $increments+=@{role='amd';ad=$v.availability_domain;amount=1};$increments+=@{role='storage';ad=$v.availability_domain;amount=$gb} }
                elseif ($before.source_details[0].boot_volume_size_in_gbs -ne $gb) { throw 'FREE_POLICY_BLOCKED: 기존 boot volume 크기 변경은 별도 검토가 필요합니다.' }
                Require-Policy (@($v.create_vnic_details).Count -eq 1 -and $v.create_vnic_details[0].assign_public_ip -eq $true) 'VM 인터넷 egress를 위한 public IPv4 누락.'
            }
            'oci_mysql_mysql_db_system' {
                Require-Policy ((Require-Known $v 'shape_name') -eq 'MySQL.Free') 'MySQL.Free 외 shape 금지.'
                Require-Policy ((Require-Known $v 'data_storage_size_in_gb') -eq 50) 'MySQL 저장소는 50GiB 고정.'
                Require-Policy ((Require-Known $v 'is_highly_available') -eq $false) 'MySQL HA 금지.'
                $deletion=@(Require-Known $v 'deletion_policy'); Require-Policy ($deletion.Count -eq 1 -and $deletion[0].is_delete_protected -eq $true) 'MySQL 삭제 보호 필수.'
                $bp=@(Require-Known $v 'backup_policy'); Require-Policy ($bp.Count -eq 1 -and $bp[0].is_enabled -eq $true -and $bp[0]['retention_in_days'] -eq 1) 'MySQL 자동백업 1일 고정.'
                $backupUnknown=if ($u.ContainsKey('backup_policy') -and $u.backup_policy -is [array]) { $u.backup_policy[0] } else { @{} }
                Require-EmptyOptional $bp[0] $backupUnknown 'copy_policies'
                Require-Policy ((Require-Known $v 'database_management') -eq 'DISABLED') '추가 Database Management 금지.'
                $read=@(Require-Known $v 'read_endpoint');Require-Policy ($read.Count -eq 1 -and $read[0].is_enabled -eq $false) 'MySQL read endpoint/replica 금지.'
                Require-Policy ($bp[0].soft_delete -eq 'DISABLED') 'MySQL backup soft delete 금지.'
                $pitr=@(Require-Known $bp[0] 'pitr_policy'); Require-Policy ($pitr.Count -eq 1 -and $pitr[0].is_enabled -eq $false) 'MySQL PITR 금지.'
                $storagePolicy=@(Require-Known $v 'data_storage'); Require-Policy ($storagePolicy.Count -eq 1 -and $storagePolicy[0].is_auto_expand_storage_enabled -eq $false) 'MySQL 자동 확장 금지.'
                if ($isNew) { $newMysql++;$increments+=@{role='mysql';ad=$v.availability_domain;amount=1} }
            }
            'oci_database_autonomous_database' {
                Require-Policy ((Require-Known $v 'is_free_tier') -eq $true) '유료 Autonomous 금지.'
                Require-Policy ((Require-Known $v 'data_storage_size_in_gb') -eq 20) 'Autonomous 20GB 고정.'
                Require-Policy ((Require-Known $v 'cpu_core_count') -eq 1 -and (Require-Known $v 'is_dedicated') -eq $false) 'Autonomous 무료 CPU/serverless 범위 이탈.'
                foreach ($key in @('is_dev_tier','is_local_data_guard_enabled','is_replicate_automatic_backups')) { Require-Policy ((Require-Known $v $key) -eq $false) "Autonomous 추가 기능 $key 금지." }
                Require-Policy ((Require-Known $v 'is_auto_scaling_enabled') -eq $false -and (Require-Known $v 'is_auto_scaling_for_storage_enabled') -eq $false) 'Autonomous 자동 확장 금지.'
                Require-Policy ((Require-Known $v 'is_mtls_connection_required') -eq $true) 'Autonomous mTLS 필수.'
                Require-Policy (@(Require-Known $v 'whitelisted_ips').Count -gt 0 -and '0.0.0.0/0' -notin $v.whitelisted_ips) 'Autonomous 제한된 IP 허용 목록 필수.'
                # Omitted optional-computed subnet_id is unknown in provider 8.5.0 even for public endpoints.
                Require-Policy (-not $v['subnet_id']) 'Always Free Autonomous private endpoint 금지.'
                if ($isNew) { $newAdb++;$increments+=@{role='autonomous';ad=$null;amount=1} }
            }
            'oci_core_security_list' {
                Require-Policy (@($v.ingress_security_rules).Count -eq 0) 'Subnet security list ingress 우회 금지: NSG만 사용합니다.'
            }
            'oci_core_network_security_group_security_rule' {
                Require-Policy ((Require-Known $v 'direction') -in @('INGRESS','EGRESS')) 'NSG 방향 미확인.'
                if ($v.direction -eq 'INGRESS') {
                    Require-Policy ($v.protocol -eq '6') 'TCP 외 ingress 금지.'
                    $tcp=@(Require-Known $v 'tcp_options'); Require-Policy ($tcp.Count -eq 1) 'NSG 포트 미확인.'
                    $range=@(Require-Known $tcp[0] 'destination_port_range'); Require-Policy ($range.Count -eq 1 -and $range[0].min -eq $range[0].max) '포트 범위 개방 금지.'
                    $port=[int]$range[0].min
                    if ($v.source_type -eq 'NETWORK_SECURITY_GROUP') {
                        throw 'FREE_POLICY_BLOCKED: 이 템플릿은 명시된 private IPv4 /32만 사용합니다. 임의/unknown NSG source 금지.'
                    } elseif ($port -eq 3306 -and $rc.address -like 'oci_core_network_security_group_security_rule.mysql_ingress*') {
                        Require-Policy ($v.source -in @($Config.servers.Values | ForEach-Object { $_.private_ip+'/32' })) 'MySQL ingress는 설정한 VM private /32만 허용.'
                    } elseif ($rc.address -like 'oci_core_network_security_group_security_rule.internal_ingress*') {
                        $matches=@($Config.internal_tcp_rules.Values | Where-Object { $_.port -eq $port -and ($Config.servers[$_.source_server].private_ip+'/32') -eq $v.source })
                        Require-Policy ($matches.Count -gt 0) '설정에 없는 내부 ingress.'
                    } elseif ($port -eq 22) { Require-Policy ($v.source -eq $Config.ssh_allowed_cidr -and $v.source -ne '0.0.0.0/0') 'SSH 관리 CIDR 이탈.' }
                    elseif ($port -eq 443) {
                        $allowedHttps=@($Config.servers.Keys | Where-Object { $Config.servers[$_].public_https -eq $true } | ForEach-Object { 'oci_core_network_security_group_security_rule.https["'+$_+'"]' })
                        Require-Policy ($v.source -eq '0.0.0.0/0' -and $rc.address -in $allowedHttps) '설정에 명시한 서버 HTTPS만 허용.'
                    }
                    else { throw 'FREE_POLICY_BLOCKED: DB/Redis/앱 포트의 CIDR 직접 공개 금지.' }
                }
            }
        }
        $summary += @{address=$rc.address; actions=$actions; before=(Get-SafeReviewValues $before); after=(Get-SafeReviewValues $v)}
    }
    Require-Policy (($amd+$newAmd) -le 2) '기존 사용량과 생성/교체 중 AMD 최대 동시 사용량 > 2.'
    Require-Policy (($mysql+$newMysql) -le 1) '기존 사용량과 생성/교체 중 무료 MySQL > 1.'
    Require-Policy (([double](Require-Known $Inventory 'mysql_backup_gb') + $newMysql*50) -le 50) '잔여 MySQL backup과 신규 무료 backup 예산 합계 > 50GiB.'
    Require-Policy (($adb+$newAdb) -le 2) '기존 사용량과 생성/교체 중 무료 Autonomous > 2.'
    Require-Policy (($storage+$newStorage) -le 200) '기존/잔여 boot+block 및 신규 boot 합계 > 200GB.'
    Require-Policy ($backups -le 5) '기존 boot/block volume backups > 5.'
    foreach ($group in @($increments | Group-Object { $_.role + ':' + $_.ad })) {
        $first=$group.Group[0];$required=($group.Group | Measure-Object -Property amount -Sum).Sum
        $checks=@($Inventory.limit_availability | Where-Object { $_.role -eq $first.role -and ($_.scope_type -eq 'REGION' -or $_.availability_domain -eq $first.ad) })
        Require-Policy ($checks.Count -gt 0) "신규 $($first.role) 의 AD/REGION quota 확인 누락."
        foreach ($check in $checks) {
            if ($check.scope_type -eq 'REGION') { $required=(@($increments | Where-Object { $_.role -eq $first.role }) | Measure-Object -Property amount -Sum).Sum }
            Require-Policy ($check.available -ge $required) "신규 $($first.role) 가 계정 잔여 quota 초과."
        }
    }
    Require-Policy ($deletions.Count -eq 0) ('삭제/교체는 이 배포 경로에서 차단됩니다: '+($deletions -join ', '))
    @{status='PASS'; peak=@{amd=$amd+$newAmd;mysql=$mysql+$newMysql;autonomous=$adb+$newAdb;compute_storage_gb=$storage+$newStorage;volume_backups=$backups}; changes=$summary; deleted_or_replaced=$deletions}
}

Export-ModuleMember -Function Test-FreePlan,Test-UnknownTree
