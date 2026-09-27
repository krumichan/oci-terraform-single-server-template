Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Get-MySqlNsgRequiredPermissions {
    # These are review metadata, not an IAM authorization evaluator. Resource-type
    # grants, group membership, conditions and inherited grants require review.
    @{
        user_compartment=@('COMPARTMENT_INSPECT')
        user_subnet=@('VCN_READ','SUBNET_READ','SUBNET_ATTACH','SUBNET_DETACH')
        user_nsg=@('NETWORK_SECURITY_GROUP_READ','NETWORK_SECURITY_GROUP_UPDATE_MEMBERS')
        user_vnic=@('VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP','VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP')
        db_principal_nsg=@('NETWORK_SECURITY_GROUP_UPDATE_MEMBERS')
        db_principal_subnet=@('VNIC_CREATE','VNIC_UPDATE','VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP','VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP')
    }
}

function Get-MySqlNsgPolicyEvidence {
    param([scriptblock]$Fetch={param($uri) (Invoke-WebRequest -Uri $uri -TimeoutSec 30 -MaximumRetryCount 1).Content})
    $uri='https://docs.oracle.com/en-us/iaas/mysql-database/doc/mandatory-policies-permissions.html'
    $content=[string](& $Fetch $uri)
    foreach ($marker in @('mysqldbsystem','request.resource.compartment.id','NETWORK_SECURITY_GROUP_UPDATE_MEMBERS','VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP','VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP')) {
        Assert-Condition ($content -match [regex]::Escape($marker)) 'MySQL NSG 공식 IAM 문서 조회/내용 확인 실패. 실행일 문서를 직접 재검토하세요.'
    }
    @{url=$uri;checked_at=[datetimeoffset]::UtcNow.ToString('o');sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content)));verification='retrieved + markers; permissions and conditions require same-day manual review'}
}

function Get-MySqlNsgIamInspection {
    param($Identity,[hashtable]$Config,[scriptblock]$Query)
    $result=@{
        status='REVIEW_REQUIRED';checked_at=[datetimeoffset]::UtcNow.ToString('o')
        tenancy_ocid=$Identity.Tenancy;region=$Config.region;compartment_ocid=$Config.compartment_ocid
        effective_authorization='NOT_PROVEN';automatic_iam_changes=$false
        source='https://docs.oracle.com/en-us/iaas/mysql-database/doc/mandatory-policies-permissions.html'
        interpretation='Read-only policy inspection and explicit-token hints do not prove effective write permissions. Review group membership, inherited statements and every condition in Console.'
        ancestor_scopes=@();policies=@();read_only_queries=@();issues=@()
        required_permissions=(Get-MySqlNsgRequiredPermissions)
    }
    if (-not $Config.mysql_enabled) { $result.status='NOT_APPLICABLE';return $result }
    $scopes=[Collections.Generic.List[string]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $current=[string]$Config.compartment_ocid
    # Current topology places DB, NSG and subnet in one compartment. Do not
    # silently accept evidence about a future, different topology.
    while ($current -cne $Identity.Tenancy) {
        if ($current -notmatch '^ocid1\.compartment\.oc1\.\.[A-Za-z0-9]+$' -or -not $seen.Add($current) -or $scopes.Count -ge 12) {
            $result.issues+=@{code='ANCESTRY_UNCONFIRMED';operation='iam compartment get';scope_ocid=$Config.compartment_ocid;action='compartment 부모 경로와 tenancy를 콘솔에서 확인하세요.'};return $result
        }
        $scopes.Add($current)
        try {
            $row=& $Query $Config.region @('iam','compartment','get','--compartment-id',$current) $false
            Assert-Condition ($row.id -ceq $current -and $row['lifecycle-state'] -eq 'ACTIVE' -and [bool]$row['compartment-id']) 'Compartment ancestry incomplete.'
            $result.read_only_queries+=@{operation='iam compartment get';scope_ocid=$current;status='SUCCEEDED'}
            $current=[string]$row['compartment-id']
        } catch {
            # Never serialize arbitrary exception/response text: fixtures and CLI
            # errors can contain secrets. Common supplies safe diagnostics on its
            # normal path; this report deliberately records only fixed fields.
            $result.issues+=@{code='ANCESTRY_READ_FAILED';operation='iam compartment get';scope_ocid=$current;action='대상과 ancestor compartment 읽기 권한/ACTIVE 상태를 관리자에게 확인하고 다시 실행하세요.'};return $result
        }
    }
    $scopes.Add([string]$Identity.Tenancy)
    $result.ancestor_scopes=@($scopes.ToArray())
    $permissionNames=@((Get-MySqlNsgRequiredPermissions).Values | ForEach-Object { $_ } | Sort-Object -Unique)
    foreach ($scope in $scopes) {
        try {
            $rows=@(& $Query $Config.region @('iam','policy','list','--compartment-id',$scope,'--all') $true)
            foreach ($row in $rows) {
                Assert-Condition ($row.id -match '^ocid1\.policy\.oc1\.\.[A-Za-z0-9]+$' -and $row['compartment-id'] -ceq $scope -and $row['lifecycle-state'] -and $row.statements -is [array]) 'Policy identity/status/statements incomplete.'
                $statements=[string]::Join("`n",[string[]]$row.statements)
                $hints=@($permissionNames | Where-Object { $statements -match "(?i)(?<![A-Z_])$([regex]::Escape($_))(?![A-Z_])" })
                $result.policies+=@{
                    id=$row.id;compartment_ocid=$scope;lifecycle_state=$row['lifecycle-state']
                    statements_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($statements)))
                    explicit_permission_hints=$hints
                    db_principal_marker_present=($statements -match "(?i)request\.principal\.type\s*=\s*'mysqldbsystem'")
                    db_compartment_marker_present=($statements -match "(?i)request\.resource\.compartment\.id\s*=\s*'$([regex]::Escape($Config.compartment_ocid))'")
                    hint_only=$true
                }
            }
            $result.read_only_queries+=@{operation='iam policy list';scope_ocid=$scope;status='SUCCEEDED';policy_count=$rows.Count}
        } catch {
            $result.issues+=@{code='POLICY_READ_FAILED';operation='iam policy list';scope_ocid=$scope;action='이 scope의 POLICY_READ 권한과 전체 페이지 조회를 관리자에게 확인하세요. 콘솔에 보이는 일부 정책만으로 통과하지 않습니다.'}
        }
    }
    if ($result.issues.Count -eq 0) { $result.status='READ_ONLY_QUERIES_SUCCEEDED' }
    return $result
}

function Test-MySqlNsgIamReadiness {
    param([hashtable]$Inspection,[hashtable]$Review,[hashtable]$Config,[string]$Tenancy,[string]$Today=(Get-Date -Format 'yyyy-MM-dd'))
    $result=@{status='REVIEW_REQUIRED';effective_authorization='NOT_PROVEN';ready=$false;issues=@();policy_ocids=@();reviewed_on=$null}
    if (-not $Config.mysql_enabled) { $result.status='NOT_APPLICABLE';$result.ready=$true;return $result }
    if ($Inspection.status -ne 'READ_ONLY_QUERIES_SUCCEEDED') { $result.issues+='IAM_READS_INCOMPLETE: iam-review.json의 조회 실패를 먼저 해결하세요.' }
    if ($Inspection.tenancy_ocid -cne $Tenancy -or $Inspection.region -cne $Config.region -or $Inspection.compartment_ocid -cne $Config.compartment_ocid) { $result.issues+='IAM_TARGET_MISMATCH: 조회와 설정 대상이 다릅니다.' }
    if (-not $Review.ContainsKey('mysql_nsg_iam') -or $Review.mysql_nsg_iam -isnot [hashtable]) { $result.issues+='IAM_EVIDENCE_MISSING: console-review.json.mysql_nsg_iam을 예제와 가이드에 따라 직접 확인하세요.';return $result }
    $evidence=$Review.mysql_nsg_iam
    if ($evidence['reviewed_on'] -cne $Today) { $result.issues+='IAM_REVIEW_STALE: 정책과 그룹 권한을 실행일에 다시 확인하세요.' }
    if ($evidence['tenancy_ocid'] -cne $Tenancy -or $evidence['region'] -cne $Config.region) { $result.issues+='IAM_EVIDENCE_TARGET_MISMATCH: IAM 근거 tenancy/region이 다릅니다.' }
    foreach ($key in @('db_compartment_ocid','nsg_compartment_ocid','subnet_compartment_ocid')) {
        if ($evidence[$key] -cne $Config.compartment_ocid) { $result.issues+="IAM_SCOPE_MISMATCH: mysql_nsg_iam.$key 는 config.compartment_ocid와 같아야 합니다." }
    }
    if ($evidence['deployer_group_ocid'] -notmatch '^ocid1\.group\.oc1\.\.[A-Za-z0-9]+$' -or $evidence['deployer_group_ocid'] -match 'REPLACE') { $result.issues+='IAM_GROUP_UNCONFIRMED: API 사용자가 속한 배포 그룹 OCID가 필요합니다.' }
    if ($evidence['policy_disposition'] -notin @('EXISTING_SUFFICIENT','CREATED_WITH_APPROVAL')) { $result.issues+='IAM_POLICY_UNREADY: 기존 정책이 충분한지 먼저 확인하고, 변경이 필요하면 별도 승인 후 준비하세요.' }
    if ($evidence['policy_disposition'] -eq 'CREATED_WITH_APPROVAL' -and ($evidence['separately_approved_change_confirmed'] -isnot [bool] -or $evidence['separately_approved_change_confirmed'] -ne $true)) { $result.issues+='IAM_CHANGE_APPROVAL_UNCONFIRMED: 별도 승인 범위에서 정책을 준비했는지 확인하세요.' }
    foreach ($key in @('api_user_group_membership_confirmed','user_permissions_confirmed','db_principal_permissions_confirmed','conditions_and_scope_confirmed','conflicts_resolved')) {
        if ($evidence[$key] -isnot [bool] -or $evidence[$key] -ne $true) { $result.issues+="IAM_MANUAL_REVIEW_REQUIRED: mysql_nsg_iam.$key 미확인(직접 확인한 JSON boolean true만 허용)." }
    }
    if ($evidence['unresolved_items'] -isnot [array] -or $evidence['unresolved_items'].Count -ne 0) { $result.issues+='IAM_UNRESOLVED: unresolved_items가 남아 있거나 누락되었습니다. 추측으로 지우지 말고 확인하세요.' }
    $policyIds=@($evidence['policy_ocids'])
    if ($evidence['policy_ocids'] -isnot [array] -or $policyIds.Count -eq 0) { $result.issues+='IAM_POLICY_EVIDENCE_MISSING: 직접 검토한 ACTIVE 정책 OCID를 policy_ocids 배열에 입력하세요.' }
    foreach ($id in $policyIds) {
        if ($id -notmatch '^ocid1\.policy\.oc1\.\.[A-Za-z0-9]+$') { $result.issues+='IAM_POLICY_ID_INVALID: 정책 OCID 형식을 확인하세요.';continue }
        $observed=@($Inspection.policies | Where-Object { $_.id -ceq $id -and $_.lifecycle_state -eq 'ACTIVE' })
        if ($observed.Count -ne 1) { $result.issues+='IAM_POLICY_NOT_ACTIVE_OR_VISIBLE: 검토한 정책이 대상/ancestor 조회에서 ACTIVE로 확인되지 않았습니다.' }
    }
    if ($result.issues.Count -eq 0) {
        $result.ready=$true;$result.status='REVIEWED_PREREQUISITES';$result.policy_ocids=$policyIds;$result.reviewed_on=$Today
    }
    return $result
}

function Get-DiscoverySuggestions {
    param([hashtable]$Config,[hashtable]$Discovery)
    $proposals=@()
    foreach ($name in @($Config.servers.Keys | Sort-Object)) {
        $proposals+=@{json_path="servers.$name.availability_domain";current=$Config.servers[$name].availability_domain;candidates=@($Discovery.availability_domains);action='콘솔의 계정별 전체 AD 이름과 맞는 값을 직접 선택'}
        $proposals+=@{json_path="servers.$name.image_ocid";current=$Config.servers[$name].image_ocid;candidates=@($Discovery.image_candidates);action='Ubuntu platform LTS/AMD Micro 후보를 직접 선택; 선택 후 Preflight에서 AD 호환성과 boot 크기 재검증'}
    }
    if ($Config.mysql_enabled) { $proposals+=@{json_path='mysql_availability_domain';current=$Config.mysql_availability_domain;candidates=@($Discovery.availability_domains);action='MySQL.Free를 제공하는 AD를 직접 선택; 일반 Preflight에서 shape 검증'} }
    $roles=@('amd','storage','backups');if ($Config.mysql_enabled) { $roles+='mysql' };if ($Config.autonomous_databases.Count -gt 0) { $roles+='autonomous' }
    $known=@{amd=@('compute','standard-e2-micro-core-count');storage=@('block-storage','total-storage-gb');backups=@('block-storage','backup-count');autonomous=@('database','adb-free-count')}
    foreach ($role in $roles) {
        $definitions=@($Discovery.limit_definitions | Where-Object {
            if ($role -eq 'mysql') { $_.service_name -eq 'mysql' -and $_.name -match 'free' -and $_.name -notmatch 'heatwave|heat-wave|storage|backup' -and $_.description -match '(?i)(MySQL[. ]Free|Always Free.*DB [Ss]ystem|Free.*MySQL.*DB [Ss]ystem)' }
            else { $_.service_name -eq $known[$role][0] -and $_.name -eq $known[$role][1] }
        })
        $proposals+=@{json_path='limit_checks[]';role=$role;candidates=$definitions;availability='NOT_QUERIED';action='service_name/name를 확인해 role과 함께 입력. scope_type=AD는 전체 availability_domain도 입력. null/미지원/후보없음은 무료 확인불가로 중단.'}
    }
    @{status='MANUAL_SELECTION_REQUIRED';config_automatically_changed=$false;console_evidence_automatically_confirmed=$false;candidate_selection_is_not_validation=$true;proposals=$proposals}
}

Export-ModuleMember -Function Get-MySqlNsgRequiredPermissions,Get-MySqlNsgPolicyEvidence,Get-MySqlNsgIamInspection,Test-MySqlNsgIamReadiness,Get-DiscoverySuggestions
