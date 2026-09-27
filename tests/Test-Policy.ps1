#requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $root 'scripts/lib/FreePolicy.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'scripts/lib/Inventory.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'scripts/lib/Common.psm1') -Force -DisableNameChecking
$script:passed=0
function Check([string]$Name,[scriptblock]$Body) { & $Body; $script:passed++; Write-Host "PASS $Name" }
function Blocks([scriptblock]$Body,[string]$Pattern='.') { try { & $Body | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }; return }; throw 'Expected rejection, but operation passed.' }
function Copy-Object($Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
function New-Fixture {
    $config=@{region='ap-seoul-1';compartment_ocid='compartment';ssh_allowed_cidr='8.8.8.8/32';servers=@{'server-1'=@{private_ip='10.0.1.10'};'server-2'=@{private_ip='10.0.1.11'}};internal_tcp_rules=@{};mysql_enabled=$true;autonomous_databases=@{};limit_checks=@()}
    $inventory=@{status='VERIFIED';complete=$true;checked_at=[datetimeoffset]::UtcNow.ToString('o');region=$config.region;home_region=$config.region;resources=@();verified_images=@('image-fixed');limit_availability=@(@{role='amd';scope_type='AD';availability_domain='AD-1';available=2},@{role='storage';scope_type='AD';availability_domain='AD-1';available=200},@{role='mysql';scope_type='AD';availability_domain='AD-1';available=1},@{role='autonomous';scope_type='REGION';availability_domain=$null;available=2})}
    $vm=@{shape='VM.Standard.E2.1.Micro';compartment_id='compartment';availability_domain='AD-1';source_details=@(@{source_type='image';source_id='image-fixed';boot_volume_size_in_gbs='50';boot_volume_vpus_per_gb='10'});create_vnic_details=@(@{assign_public_ip=$true})}
    $mysql=@{shape_name='MySQL.Free';compartment_id='compartment';availability_domain='AD-1';data_storage_size_in_gb=50;is_highly_available=$false;deletion_policy=@(@{is_delete_protected=$true});backup_policy=@(@{is_enabled=$true;retention_in_days=1;soft_delete='DISABLED';pitr_policy=@(@{is_enabled=$false})});data_storage=@(@{is_auto_expand_storage_enabled=$false})}
    $adb=@{compartment_id='compartment';is_free_tier=$true;data_storage_size_in_gb=20;is_auto_scaling_enabled=$false;is_auto_scaling_for_storage_enabled=$false;is_mtls_connection_required=$true;whitelisted_ips=@('8.8.8.8/32');subnet_id=$null}
    $changes=@()
    foreach ($key in @('server-1','server-2')) { $changes+=@{address="oci_core_instance.server[`"$key`"]";mode='managed';type='oci_core_instance';change=@{actions=@('create');before=$null;after=(Copy-Object $vm);after_unknown=@{}}} }
    $changes+=@{address='oci_mysql_mysql_db_system.free[0]';mode='managed';type='oci_mysql_mysql_db_system';change=@{actions=@('create');before=$null;after=$mysql;after_unknown=@{}}}
    $inventory.mysql_backup_gb=0
    foreach ($server in $config.servers.Values) { $server.public_https=$false }
    foreach ($rc in $changes | Where-Object { $_.type -eq 'oci_core_instance' }) { foreach ($key in @('licensing_configs','launch_volume_attachments','shape_config')) { $rc.change.after[$key]=@() };$rc.change.after.is_ai_enterprise_enabled=$false }
    $mysql.backup_policy[0].copy_policies=@();$mysql.database_management='DISABLED';$mysql.read_endpoint=@(@{is_enabled=$false})
    $adb.cpu_core_count=1;$adb.is_dedicated=$false
    foreach ($key in @('is_dev_tier','is_local_data_guard_enabled','is_replicate_automatic_backups')) {$adb[$key]=$false}
    @{Config=$config;Inventory=$inventory;Plan=@{resource_changes=$changes};Adb=$adb}
}
function Evaluate($Fixture) { Test-FreePlan -Plan $Fixture.Plan -Inventory $Fixture.Inventory -Config $Fixture.Config }

Check 'default 2 AMD + 1 MySQL, peak100' { $f=New-Fixture; $r=Evaluate $f; Assert-Condition ($r.peak.amd -eq 2 -and $r.peak.mysql -eq 1 -and $r.peak.compute_storage_gb -eq 100) 'bad peak' }
Check 'single VM, MySQL off' { $f=New-Fixture;$f.Plan.resource_changes=@($f.Plan.resource_changes[0]);$r=Evaluate $f;Assert-Condition ($r.peak.amd -eq 1 -and $r.peak.mysql -eq 0) 'single regression' }
foreach ($count in @(1,2)) { Check "Autonomous opt-in $count" { $f=New-Fixture;for($i=0;$i -lt $count;$i++) {$f.Plan.resource_changes+=@{address="oci_database_autonomous_database.free[$i]";mode='managed';type='oci_database_autonomous_database';change=@{actions=@('create');before=$null;after=(Copy-Object $f.Adb);after_unknown=@{}}}};$r=Evaluate $f;Assert-Condition ($r.peak.autonomous -eq $count) 'ADB count' } }
Check 'third AMD blocks' { $f=New-Fixture;$f.Plan.resource_changes+=Copy-Object $f.Plan.resource_changes[0];Blocks {Evaluate $f} 'AMD' }
Check 'second MySQL blocks' { $f=New-Fixture;$f.Inventory.resources=@(@{id='existing-mysql';kind='mysql';shape='MySQL.Free'});Blocks {Evaluate $f} 'MySQL' }
Check 'third Autonomous blocks' { $f=New-Fixture;$f.Inventory.resources=@(@{id='a';kind='autonomous';is_free_tier=$true},@{id='b';kind='autonomous';is_free_tier=$true});$f.Plan.resource_changes+=@{address='adb';mode='managed';type='oci_database_autonomous_database';change=@{actions=@('create');before=$null;after=$f.Adb;after_unknown=@{}}};Blocks {Evaluate $f} 'Autonomous' }
Check 'retained boot causes >200GB' { $f=New-Fixture;$f.Inventory.resources=@(@{id='retained';kind='boot';size_gb=101;vpus_per_gb=10});Blocks {Evaluate $f} '200GB' }
Check 'existing AMD counts across compartments' { $f=New-Fixture;$f.Inventory.resources=@(@{id='other';kind='instance';shape='VM.Standard.E2.1.Micro'});Blocks {Evaluate $f} 'AMD' }
Check 'managed no-op is not counted twice' { $f=New-Fixture;$f.Plan.resource_changes=@($f.Plan.resource_changes[0]);$c=$f.Plan.resource_changes[0].change;$c.actions=@('no-op');$c.before=Copy-Object $c.after;$c.before.id='managed';$f.Inventory.resources=@(@{id='managed';kind='instance';shape='VM.Standard.E2.1.Micro'},@{id='boot';kind='boot';size_gb=50;vpus_per_gb=10});$r=Evaluate $f;Assert-Condition ($r.peak.amd -eq 1 -and $r.peak.compute_storage_gb -eq 50) 'double count' }
Check 'paid to free update cannot undercount' { $f=New-Fixture;$c=$f.Plan.resource_changes[0].change;$c.actions=@('update');$c.before=Copy-Object $c.after;$c.before.id='paid';$f.Inventory.resources=@(@{id='paid';kind='instance';shape='VM.Standard.E4.Flex'});Blocks {Evaluate $f} '전환' }
Check 'retained mysql backup reserves new backup headroom' { $f=New-Fixture;$f.Inventory.mysql_backup_gb=1;Blocks {Evaluate $f} 'backup' }
Check 'cross region backup copy prohibited' { $f=New-Fixture;$f.Plan.resource_changes[2].change.after.backup_policy[0].copy_policies=@(@{region='other'});Blocks {Evaluate $f} 'copy_policies' }
Check 'unknown license conditions prohibited' { $f=New-Fixture;$f.Plan.resource_changes[0].change.after_unknown.licensing_configs=$true;Blocks {Evaluate $f} 'unknown' }
Check 'create_before_destroy temporary peak blocks' { $f=New-Fixture;$f.Plan.resource_changes=@($f.Plan.resource_changes[0]);$c=$f.Plan.resource_changes[0].change;$c.actions=@('create','delete');$f.Inventory.resources=@(@{id='old1';kind='instance';shape='VM.Standard.E2.1.Micro'},@{id='old2';kind='instance';shape='VM.Standard.E2.1.Micro'});Blocks {Evaluate $f} 'AMD' }
Check 'destroy_before_create also blocks without freeing capacity' { $f=New-Fixture;$f.Plan.resource_changes[0].change.actions=@('delete','create');Blocks {Evaluate $f} '삭제/교체' }
Check 'home region mismatch' { $f=New-Fixture;$f.Inventory.home_region='ap-osaka-1';Blocks {Evaluate $f} 'home region' }
Check 'paid shape' { $f=New-Fixture;$f.Plan.resource_changes[0].change.after.shape='VM.Standard.E4.Flex';Blocks {Evaluate $f} 'shape' }
Check 'unverified pinned image' { $f=New-Fixture;$f.Plan.resource_changes[0].change.after.source_details[0].source_id='new-image';Blocks {Evaluate $f} 'image' }
Check 'unknown boot size' { $f=New-Fixture;$f.Plan.resource_changes[0].change.after.source_details[0].boot_volume_size_in_gbs=$null;Blocks {Evaluate $f} 'unknown' }
Check 'unknown free classification' { $f=New-Fixture;$f.Plan.resource_changes[2].change.after.shape_name=$null;Blocks {Evaluate $f} 'unknown' }
Check 'expensive volume performance' { $f=New-Fixture;$f.Plan.resource_changes[0].change.after.source_details[0].boot_volume_vpus_per_gb='20';Blocks {Evaluate $f} '성능' }
Check 'HA enabled' { $f=New-Fixture;$f.Plan.resource_changes[2].change.after.is_highly_available=$true;Blocks {Evaluate $f} 'HA' }
Check 'PITR enabled' { $f=New-Fixture;$f.Plan.resource_changes[2].change.after.backup_policy[0].pitr_policy[0].is_enabled=$true;Blocks {Evaluate $f} 'PITR' }
Check 'auto storage enabled' { $f=New-Fixture;$f.Plan.resource_changes[2].change.after.data_storage[0].is_auto_expand_storage_enabled=$true;Blocks {Evaluate $f} '자동 확장' }
Check 'six volume backups' { $f=New-Fixture;$f.Inventory.resources=@(1..6 | ForEach-Object { @{id="backup$_";kind='boot_backup'} });Blocks {Evaluate $f} 'backups' }
Check 'unknown resource type NAT' { $f=New-Fixture;$f.Plan.resource_changes[0].type='oci_core_nat_gateway';Blocks {Evaluate $f} '종류' }
Check 'incomplete inventory' { $f=New-Fixture;$f.Inventory.complete=$false;Blocks {Evaluate $f} '미완료' }
Check 'stale inventory' { $f=New-Fixture;$f.Inventory.checked_at=[datetimeoffset]::UtcNow.AddMinutes(-31).ToString('o');Blocks {Evaluate $f} '30분' }
Check 'quota availability insufficient' { $f=New-Fixture;$f.Inventory.limit_availability[0].available=1;Blocks {Evaluate $f} 'quota' }
Check 'quota wrong AD cannot satisfy' { $f=New-Fixture;$f.Inventory.limit_availability[0].availability_domain='AD-2';Blocks {Evaluate $f} '누락' }
foreach ($port in @(22,3306,6379,8080,8000)) { Check "internet ingress $port denied" { $f=New-Fixture;$f.Plan.resource_changes+=@{address='unsafe';mode='managed';type='oci_core_network_security_group_security_rule';change=@{actions=@('create');before=$null;after_unknown=@{};after=@{direction='INGRESS';protocol='6';source_type='CIDR_BLOCK';source='0.0.0.0/0';tcp_options=@(@{destination_port_range=@(@{min=$port;max=$port})})}}};Blocks {Evaluate $f} 'FREE_POLICY_BLOCKED' } }
Check 'security list cannot bypass NSG' { $f=New-Fixture;$f.Plan.resource_changes+=@{address='unsafe';mode='managed';type='oci_core_security_list';change=@{actions=@('create');before=$null;after_unknown=@{};after=@{ingress_security_rules=@(@{source='0.0.0.0/0'})}}};Blocks {Evaluate $f} '우회' }
Check 'map order does not change accounting' { $f=New-Fixture;$a=Evaluate $f;[array]::Reverse($f.Plan.resource_changes);$b=Evaluate $f;Assert-Condition ($a.peak.amd -eq $b.peak.amd -and $a.peak.compute_storage_gb -eq $b.peak.compute_storage_gb) 'map order changed peak' }
Check 'native exit 0/2 accepted, 1 rejected and secrets masked' {
    $exe=(Get-Process -Id $PID).Path
    foreach ($code in @(0,2)) { $r=Invoke-NativeTool -FilePath $exe -Arguments @('-NoProfile','-Command',"exit $code") -AcceptedExitCodes @(0,2);Assert-Condition ($r.ExitCode -eq $code) 'bad native code' }
    try { Invoke-NativeTool -FilePath $exe -Arguments @('-NoProfile','-Command','[Console]::Error.WriteLine("SECRET_SENTINEL"); exit 1') | Out-Null;throw 'did not reject' } catch { Assert-Condition ($_.Exception.Message -match 'exit=1' -and $_.Exception.Message -notmatch 'SECRET_SENTINEL') 'native secret/error handling broken' }
}
Check 'OCI --all/pagination/null failures' {
    $module=Get-Module Common
    & $module { function script:Invoke-NativeTool { [pscustomobject]@{Stdout='{"data": [], "opc-next-page":"more"}';Stderr='';ExitCode=0} } }
    Blocks { Invoke-OciJson -Identity ([pscustomobject]@{ConfigPath='config';Profile='p'}) -Region 'r' -Arguments @('compute','instance','list') -List } '--all'
    Blocks { Invoke-OciJson -Identity ([pscustomobject]@{ConfigPath='config';Profile='p'}) -Region 'r' -Arguments @('compute','instance','list','--all') -List } 'pagination'
    & $module { function script:Invoke-NativeTool { [pscustomobject]@{Stdout='{"data": null}';Stderr='';ExitCode=0} } }
    Blocks { Invoke-OciJson -Identity ([pscustomobject]@{ConfigPath='config';Profile='p'}) -Region 'r' -Arguments @('get') } 'data'
    Import-Module (Join-Path $root 'scripts/lib/Common.psm1') -Force -DisableNameChecking
}
Check 'all compartments/regions enumerated and permission failure stops' {
    $f=New-Fixture;$f.Config.compartment_ocid='compartment';$script:calls=[Collections.Generic.List[string]]::new()
    $query={param($region,$arguments,$list)
        $cmd=$arguments -join ' ';$script:calls.Add($region+' '+$cmd)
        if ($cmd -like 'iam region-subscription*') { return @(@{'is-home-region'=$true;'region-name'='ap-seoul-1';status='READY'},@{'is-home-region'=$false;'region-name'='ap-osaka-1';status='READY'}) }
        if ($cmd -like 'iam compartment*') { return @(@{id='compartment';'lifecycle-state'='ACTIVE'},@{id='hidden-child';'lifecycle-state'='ACTIVE'}) }
        if ($cmd -like 'iam availability-domain*') { return @(@{name='AD-1'}) }
        return @()
    }
    $r=Get-AccountInventory -Identity ([pscustomobject]@{Tenancy='tenancy'}) -Config $f.Config -Query $query
    Assert-Condition ($r.compartments.Count -eq 3 -and $r.regions.Count -eq 2 -and @($script:calls | Where-Object { $_ -like '*hidden-child*' }).Count -eq 16) 'cross-compartment/region enumeration incomplete'
    $fail={param($region,$arguments,$list) if (($arguments -join ' ') -like '*hidden-child*') {throw 'NotAuthorized'}; & $query $region $arguments $list }.GetNewClosure()
    Blocks { Get-AccountInventory -Identity ([pscustomobject]@{Tenancy='tenancy'}) -Config $f.Config -Query $fail } 'NotAuthorized'
}
Write-Host "Policy/workflow tests: $script:passed PASS (offline/mock); live OCI/DB NOT_RUN"
