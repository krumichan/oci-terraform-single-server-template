Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function New-AutonomousVerification {
    param([hashtable]$Configured,[hashtable]$Outputs,[string]$Tenancy,[string]$Region,[string]$Compartment)
    $keys=@(@($Configured.Keys)+@($Outputs.Keys) | Sort-Object -Unique)
    $resources=@()
    foreach ($key in $keys) { $resources+=@{name=$key;status='NOT_RUN';api_query='NOT_RUN';wallet='NOT_RUN';database_connection='NOT_RUN';checks=@{}} }
    return @{status=$(if ($keys.Count -eq 0) {'NOT_APPLICABLE'} else {'NOT_RUN'});target=@{tenancy_ocid=$Tenancy;region=$Region;compartment_ocid=$Compartment};configured_count=$Configured.Count;state_count=$Outputs.Count;wallet=$(if ($keys.Count -eq 0) {'NOT_APPLICABLE'} else {'NOT_RUN'});database_connection=$(if ($keys.Count -eq 0) {'NOT_APPLICABLE'} else {'NOT_RUN'});resources=$resources}
}

function Assert-AutonomousOutputSet {
    param([hashtable]$Configured,[hashtable]$Outputs)
    Assert-Condition ($Configured.Count -le 2 -and $Outputs.Count -le 2) 'ADB_COUNT_INVALID: Autonomous는 최대 2개입니다.'
    Assert-Condition ((@($Configured.Keys | Sort-Object) -join ',') -ceq (@($Outputs.Keys | Sort-Object) -join ',')) 'ADB_OUTPUT_SET_MISMATCH: 설정과 State의 Autonomous 목록이 다릅니다.'
    $ids=@()
    foreach ($key in $Configured.Keys) {
        Assert-Condition ($Outputs[$key].id -match '^ocid1\.autonomousdatabase\.oc1\.' -and $Outputs[$key].db_name -ieq $Configured[$key].db_name) 'ADB_OUTPUT_TARGET_MISMATCH: Autonomous OCID/db_name을 확인하세요.'
        $ids+=$Outputs[$key].id
    }
    Assert-Condition (@($ids | Sort-Object -Unique).Count -eq $ids.Count) 'ADB_DUPLICATE_OCID: Autonomous State OCID가 중복되었습니다.'
}

function Test-AutonomousLiveResponse {
    param([hashtable]$Live,[hashtable]$Expected,[string]$Id,[string]$Compartment)
    $checks=[ordered]@{}
    $checks.id=($Live.ContainsKey('id') -and $Live.id -ceq $Id)
    $checks.compartment=($Live.ContainsKey('compartment-id') -and $Live['compartment-id'] -ceq $Compartment)
    # Oracle database names are case insensitive; Terraform's optional workload
    # defaults to OLTP when a config entry omits the field.
    $checks.db_name=($Live.ContainsKey('db-name') -and $Live['db-name'] -ieq $Expected.db_name)
    $workload='OLTP'; if ($Expected.ContainsKey('db_workload') -and $null -ne $Expected.db_workload) { $workload=$Expected.db_workload }
    $checks.workload=($Live.ContainsKey('db-workload') -and $Live['db-workload'] -ceq $workload)
    $checks.lifecycle=($Live.ContainsKey('lifecycle-state') -and $Live['lifecycle-state'] -ceq 'AVAILABLE')
    $checks.storage_20_gb=($Live.ContainsKey('data-storage-size-in-gbs') -and $null -ne $Live['data-storage-size-in-gbs'] -and $Live['data-storage-size-in-gbs'] -eq 20)
    $checks.cpu_one=($Live.ContainsKey('cpu-core-count') -and $null -ne $Live['cpu-core-count'] -and $Live['cpu-core-count'] -eq 1)
    foreach ($field in @('is-free-tier','is-mtls-connection-required')) { $checks[$field]=($Live.ContainsKey($field) -and $Live[$field] -is [bool] -and $Live[$field]) }
    foreach ($field in @('is-auto-scaling-enabled','is-auto-scaling-for-storage-enabled','is-dedicated','is-dev-tier','is-local-data-guard-enabled')) { $checks[$field]=($Live.ContainsKey($field) -and $Live[$field] -is [bool] -and -not $Live[$field]) }
    $expectedAcl=@($Expected.whitelisted_ips | Sort-Object -Unique)
    $actualAcl=@(); if ($Live.ContainsKey('whitelisted-ips') -and $null -ne $Live['whitelisted-ips']) { $actualAcl=@($Live['whitelisted-ips'] | Sort-Object -Unique) }
    $checks.access_control=($expectedAcl.Count -gt 0 -and $actualAcl.Count -gt 0 -and ($actualAcl -join ',') -ceq ($expectedAcl -join ',') -and '0.0.0.0/0' -notin $actualAcl)
    $failed=@($checks.Keys | Where-Object { -not $checks[$_] })
    return @{status=$(if ($failed.Count -eq 0) {'PASS'} else {'FAIL'});checks=$checks;failed_checks=$failed;observed=@{id=$Live['id'];compartment_ocid=$Live['compartment-id'];db_name=$Live['db-name'];lifecycle_state=$Live['lifecycle-state'];storage_gb=$Live['data-storage-size-in-gbs'];is_free_tier=$Live['is-free-tier'];mtls_required=$Live['is-mtls-connection-required'];whitelisted_ips=$actualAcl};wallet='NOT_RUN';database_connection='NOT_RUN'}
}

Export-ModuleMember -Function New-AutonomousVerification,Assert-AutonomousOutputSet,Test-AutonomousLiveResponse
