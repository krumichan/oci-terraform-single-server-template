#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
if (-not $ScratchRoot) { $ScratchRoot=Join-Path ([IO.Path]::GetTempPath()) 'translacat-iam-tests' }
$runRoot=Join-Path ([IO.Path]::GetFullPath($ScratchRoot)) ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
Import-Module (Join-Path $repoRoot 'scripts/lib/Iam.psm1') -Force -DisableNameChecking
$results=[Collections.Generic.List[object]]::new()
function Assert-Test([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Test([string]$Name,[scriptblock]$Body,[string]$Kind='MOCK') {
    & $Body
    $results.Add(@{name=$Name;kind=$Kind;status='PASS'})
    Write-Host "PASS [$Kind] $Name"
}
function Copy-Data($Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 }
$identity=@{Tenancy='ocid1.tenancy.oc1..synthetic'}
$config=@{mysql_enabled=$true;region='ap-osaka-1';compartment_ocid='ocid1.compartment.oc1..project';servers=@{'server-1'=@{availability_domain='REPLACE';image_ocid='REPLACE'}};mysql_availability_domain='REPLACE';autonomous_databases=@{};limit_checks=@()}
$policyId='ocid1.policy.oc1..mysqlnsg'
$state=@{calls=[Collections.Generic.List[object]]::new();failure='';empty=$false;cycle=$false;policy_state='ACTIVE';policy_statements=@('Allow any-user to {NETWORK_SECURITY_GROUP_UPDATE_MEMBERS} in compartment id ocid1.compartment.oc1..project where all {request.principal.type=''mysqldbsystem'', request.resource.compartment.id=''ocid1.compartment.oc1..project''}');malformed_policy=$false;inactive_compartment=$false}
$query={
    param($region,$arguments,$list)
    $operation=$arguments[0..2] -join ' '
    $scope=$arguments[[Array]::IndexOf($arguments,'--compartment-id')+1]
    $state.calls.Add(@{operation=$operation;scope=$scope;all=('--all' -in $arguments);list=$list})
    if ($state.failure -eq $operation) { throw 'Synthetic-secret=password! API-PRIVATE-KEY SQL SELECT password; status 403 NotAuthorizedOrNotFound' }
    if ($operation -eq 'iam compartment get') {
        $parent=if ($scope -eq 'ocid1.compartment.oc1..project') {'ocid1.compartment.oc1..parent'} else {'ocid1.tenancy.oc1..synthetic'}
        if ($state.cycle) { $parent=$scope }
        return @{id=$scope;'compartment-id'=$parent;'lifecycle-state'=$(if($state.inactive_compartment){'INACTIVE'}else{'ACTIVE'})}
    }
    if ($operation -eq 'iam policy list') {
        if ($state.empty -or $scope -ne 'ocid1.tenancy.oc1..synthetic') { return @() }
        if ($state.malformed_policy) { return @{id=$policyId;'compartment-id'=$scope;'lifecycle-state'='ACTIVE'} }
        return @{id=$policyId;'compartment-id'=$scope;'lifecycle-state'=$state.policy_state;statements=$state.policy_statements}
    }
    throw 'TEST BLOCK: unexpected operation; no live calls allowed.'
}.GetNewClosure()
$review=@{mysql_nsg_iam=@{
    reviewed_on=(Get-Date -Format 'yyyy-MM-dd');tenancy_ocid=$identity.Tenancy;region=$config.region
    db_compartment_ocid=$config.compartment_ocid;nsg_compartment_ocid=$config.compartment_ocid;subnet_compartment_ocid=$config.compartment_ocid
    deployer_group_ocid='ocid1.group.oc1..deployers';policy_disposition='EXISTING_SUFFICIENT';policy_ocids=@($policyId)
    api_user_group_membership_confirmed=$true;user_permissions_confirmed=$true;db_principal_permissions_confirmed=$true
    conditions_and_scope_confirmed=$true;conflicts_resolved=$true;separately_approved_change_confirmed=$false;unresolved_items=@()
}}
$inspection=Get-MySqlNsgIamInspection -Identity $identity -Config $config -Query $query
function Get-Readiness($Evidence=$review,$InspectionValue=$inspection,$Settings=$config) { Test-MySqlNsgIamReadiness -Inspection $InspectionValue -Review $Evidence -Config $Settings -Tenancy $identity.Tenancy }
Invoke-Test 'inspect target and all ancestors with pagination' {
    Assert-Test ($inspection.status -eq 'READ_ONLY_QUERIES_SUCCEEDED' -and $inspection.ancestor_scopes.Count -eq 3) 'Ancestor scope missing.'
    Assert-Test (@($state.calls | Where-Object { $_.operation -eq 'iam policy list' -and $_.all -and $_.list }).Count -eq 3) 'Policy pagination incomplete.'
    Assert-Test ($inspection.effective_authorization -eq 'NOT_PROVEN' -and -not $inspection.automatic_iam_changes) 'Read-only inspection overstated permissions.'
}
Invoke-Test 'existing policy and complete human review permits prerequisite gate only' {
    $r=Get-Readiness
    Assert-Test ($r.ready -and $r.status -eq 'REVIEWED_PREREQUISITES' -and $r.effective_authorization -eq 'NOT_PROVEN') 'Existing reviewed policy rejected or overstated.'
}
Invoke-Test 'new account with no policies blocks even if attested' {
    $state.empty=$true
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test (-not (Get-Readiness $review $i).ready) 'Empty account policies accepted.' } finally { $state.empty=$false }
}
Invoke-Test 'new policy with separate approved change and review is accepted' {
    $r=Copy-Data $review;$r.mysql_nsg_iam.policy_disposition='CREATED_WITH_APPROVAL';$r.mysql_nsg_iam.separately_approved_change_confirmed=$true
    Assert-Test (Get-Readiness $r).ready 'Approved preparation blocked.'
}
Invoke-Test 'new policy without separate approval blocks' {
    $r=Copy-Data $review;$r.mysql_nsg_iam.policy_disposition='CREATED_WITH_APPROVAL'
    Assert-Test (-not (Get-Readiness $r).ready) 'IAM approval missing was accepted.'
}
Invoke-Test 'policy read permission failure blocks and does not leak exception secrets' {
    $state.failure='iam policy list'
    try {
        $i=Get-MySqlNsgIamInspection $identity $config $query
        Assert-Test ($i.status -eq 'REVIEW_REQUIRED' -and -not (Get-Readiness $review $i).ready) 'Policy read denial accepted.'
        Assert-Test (($i|ConvertTo-Json -Depth 100) -notmatch 'Synthetic-secret|API-PRIVATE-KEY|SELECT password') 'Secret leaked.'
        Assert-Test ($i.issues[0].code -eq 'POLICY_READ_FAILED' -and $i.issues[0].scope_ocid) 'Useful safe failure context absent.'
    } finally { $state.failure='' }
}
Invoke-Test 'ancestor read permission failure blocks' {
    $state.failure='iam compartment get'
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test (-not (Get-Readiness $review $i).ready) 'Missing ancestor access accepted.' } finally { $state.failure='' }
}
Invoke-Test 'ancestor cycle blocks' {
    $state.cycle=$true
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test ($i.issues[0].code -eq 'ANCESTRY_UNCONFIRMED') 'Ancestor cycle accepted.' } finally { $state.cycle=$false }
}
Invoke-Test 'inactive compartment blocks' {
    $state.inactive_compartment=$true
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test ($i.status -eq 'REVIEW_REQUIRED') 'Inactive compartment accepted.' } finally { $state.inactive_compartment=$false }
}
Invoke-Test 'malformed policy response blocks' {
    $state.malformed_policy=$true
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test (-not (Get-Readiness $review $i).ready) 'Malformed policy accepted.' } finally { $state.malformed_policy=$false }
}
Invoke-Test 'nonactive policy cannot support review' {
    $state.policy_state='INACTIVE'
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test (-not (Get-Readiness $review $i).ready) 'Inactive policy accepted.' } finally { $state.policy_state='ACTIVE' }
}
Invoke-Test 'string matches without human review do not prove authorization' {
    Assert-Test ($inspection.policies[0].db_principal_marker_present -and $inspection.policies[0].db_compartment_marker_present) 'Fixture tokens absent.'
    $r=Get-Readiness @{}
    Assert-Test (-not $r.ready -and $r.effective_authorization -eq 'NOT_PROVEN') 'Tokens treated as effective grant.'
}
Invoke-Test 'aggregate resource grants still require human review instead of false token proof' {
    $old=$state.policy_statements;$state.policy_statements=@('Allow group id ocid1.group.oc1..deployers to use virtual-network-family in compartment id ocid1.compartment.oc1..project')
    try { $i=Get-MySqlNsgIamInspection $identity $config $query;Assert-Test ($i.policies[0].explicit_permission_hints.Count -eq 0 -and (Get-Readiness $review $i).effective_authorization -eq 'NOT_PROVEN') 'Aggregate interpreted as effective authorization.' } finally { $state.policy_statements=$old }
}
foreach ($field in @('api_user_group_membership_confirmed','user_permissions_confirmed','db_principal_permissions_confirmed','conditions_and_scope_confirmed','conflicts_resolved')) {
    $fieldName=$field
    Invoke-Test "unconfirmed $fieldName blocks" {
        $r=Copy-Data $review;$r.mysql_nsg_iam[$fieldName]=$false
        Assert-Test (-not (Get-Readiness $r).ready) 'Unconfirmed flag accepted.'
    }
}
Invoke-Test 'conflict or unknown item blocks' {
    $r=Copy-Data $review;$r.mysql_nsg_iam.unresolved_items=@('request condition is not understood')
    Assert-Test (-not (Get-Readiness $r).ready) 'Unresolved condition accepted.'
}
Invoke-Test 'string True cannot masquerade as human boolean confirmation' {
    $r=Copy-Data $review;$r.mysql_nsg_iam.user_permissions_confirmed='True'
    Assert-Test (-not (Get-Readiness $r).ready) 'String evidence was coerced to a boolean.'
}
Invoke-Test 'old review blocks' {
    $r=Copy-Data $review;$r.mysql_nsg_iam.reviewed_on=(Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
    Assert-Test (-not (Get-Readiness $r).ready) 'Stale review accepted.'
}
foreach ($field in @('tenancy_ocid','region','db_compartment_ocid','nsg_compartment_ocid','subnet_compartment_ocid','deployer_group_ocid')) {
    $fieldName=$field
    Invoke-Test "wrong evidence $fieldName blocks" {
        $r=Copy-Data $review;$r.mysql_nsg_iam[$fieldName]='REPLACE'
        Assert-Test (-not (Get-Readiness $r).ready) 'Wrong evidence target accepted.'
    }
}
Invoke-Test 'inspection target mismatch blocks' {
    $i=Copy-Data $inspection;$i.region='us-ashburn-1'
    Assert-Test (-not (Get-Readiness $review $i).ready) 'Cross-region inspection accepted.'
}
Invoke-Test 'policy not listed in ancestors blocks' {
    $r=Copy-Data $review;$r.mysql_nsg_iam.policy_ocids=@('ocid1.policy.oc1..notobserved')
    Assert-Test (-not (Get-Readiness $r).ready) 'Unobserved policy accepted.'
}
Invoke-Test 'mysql off makes no IAM query' {
    $c=Copy-Data $config;$c.mysql_enabled=$false
    $i=Get-MySqlNsgIamInspection $identity $c {throw 'TEST BLOCK: IAM should not run when MySQL is off'}
    Assert-Test ($i.status -eq 'NOT_APPLICABLE' -and (Get-Readiness @{} $i $c).status -eq 'NOT_APPLICABLE') 'OFF IAM queried.'
}
Invoke-Test 'official source fetch evidence uses markers and hash without semantic guarantee' {
    $e=Get-MySqlNsgPolicyEvidence {param($uri) 'mysqldbsystem request.resource.compartment.id NETWORK_SECURITY_GROUP_UPDATE_MEMBERS VNIC_ASSOCIATE_NETWORK_SECURITY_GROUP VNIC_DISASSOCIATE_NETWORK_SECURITY_GROUP'}
    Assert-Test ($e.sha256.Length -eq 64 -and $e.verification -match 'manual review') 'Official evidence invalid.'
}
Invoke-Test 'official source changes fail closed' {
    $threw=$false;try { Get-MySqlNsgPolicyEvidence {param($uri) 'not the expected document'} | Out-Null } catch { $threw=$true }
    Assert-Test $threw 'Missing source markers accepted.'
}
$discovery=@{availability_domains=@('synthetic:AP-OSAKA-1-AD-1');image_candidates=@(@{id='ocid1.image.oc1.aposaka1.synthetic';display_name='Canonical-Ubuntu';os_version='24.04';size_in_mbs=50000});limit_definitions=@(@{service_name='compute';name='standard-e2-micro-core-count';description='AMD';scope_type='AD';availability_supported=$null},@{service_name='mysql';name='mysql-free-count';description='MySQL.Free DB System';scope_type='REGION';availability_supported=$false})}
Invoke-Test 'discovery gives exact input paths and preserves unsupported or unknown limits' {
    $before=$config | ConvertTo-Json -Depth 100 -Compress
    $s=Get-DiscoverySuggestions $config $discovery
    Assert-Test (-not $s.config_automatically_changed -and -not $s.console_evidence_automatically_confirmed) 'Discovery auto confirmed.'
    Assert-Test (@($s.proposals | Where-Object {$_.json_path -eq 'servers.server-1.image_ocid'}).Count -eq 1) 'Image JSON path missing.'
    $amd=@($s.proposals | Where-Object {$_['role'] -eq 'amd'})[0]
    $mysql=@($s.proposals | Where-Object {$_['role'] -eq 'mysql'})[0]
    Assert-Test ($null -eq $amd.candidates[0].availability_supported -and $mysql.candidates[0].availability_supported -ceq $false -and $amd.availability -eq 'NOT_QUERIED') 'Unsupported or unknown value was coerced.'
    Assert-Test (($config | ConvertTo-Json -Depth 100 -Compress) -ceq $before) 'User config changed.'
}
Invoke-Test 'example defaults require manual review and IAM template is compartment scoped' {
    $e=Get-Content -Raw (Join-Path $repoRoot 'examples/console-review.json.example') | ConvertFrom-Json -AsHashtable
    Assert-Test (-not (Get-Readiness $e).ready -and $e.mysql_nsg_iam.policy_disposition -eq 'UNREVIEWED') 'Example starts approved.'
    $lines=@(Get-Content (Join-Path $repoRoot 'examples/mysql-nsg-policy.txt.example') | Where-Object {$_ -match '^Allow '})
    Assert-Test ($lines.Count -eq 7 -and @($lines | Where-Object {$_ -notmatch ' in compartment id '}).Count -eq 0) 'Policy has broad tenancy scope.'
    Assert-Test (@($lines | Where-Object {$_ -match '^Allow any-user ' -and $_ -match "request.principal.type='mysqldbsystem'" -and $_ -match "request.resource.compartment.id='<DB_COMPARTMENT_OCID>'"}).Count -eq 2) 'DB principal restrictions missing.'
} 'STATIC'
$resultPath=Join-Path $runRoot 'results.json'
@{status='PASS';tests=$results.Count;results=@($results.ToArray());live_iam='NOT_RUN';automatic_mutations='NONE'} | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $resultPath -Encoding utf8
Write-Host "IAM tests: $($results.Count) passed; OCI/IAM changes NOT_RUN. Evidence: $resultPath"
