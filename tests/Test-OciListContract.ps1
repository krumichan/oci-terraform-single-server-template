#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$RendererPythonPath=$env:OCI_CONTRACT_PYTHON,
    [string]$CliPath=$env:OCI_CONTRACT_CLI,
    [string]$EvidenceDirectory=(Join-Path $PSScriptRoot '../.local/validation/oci-list-contract')
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $PSScriptRoot 'fixtures/oci_cli_render.py'
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory)
[void][IO.Directory]::CreateDirectory($evidence)
Import-Module (Join-Path $root 'scripts/lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'scripts/lib/Inventory.psm1') -Force -DisableNameChecking
$module=Get-Module Common
$actualRenderer=([bool]$RendererPythonPath -and [bool]$CliPath)
if ([bool]$RendererPythonPath -xor [bool]$CliPath) { throw 'OCI_CONTRACT_TOOLS_INCOMPLETE: Python과 격리 OCI CLI 경로를 함께 지정하세요.' }
if ($actualRenderer) {
    foreach ($path in @($RendererPythonPath,$CliPath,$fixture)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'OCI_CONTRACT_TOOL_MISSING: 지정한 도구/fixture를 확인하세요.' } }
}
$native=(Get-Command Invoke-NativeTool).ScriptBlock
& $module {
    param($python,$cli,$fixturePath,$nativeScript,$useRenderer)
    $script:contractPython=$python;$script:contractCli=$cli;$script:contractFixture=$fixturePath
    $script:contractRealNative=$nativeScript;$script:contractActual=$useRenderer
    $script:contractOverride=$null;$script:contractVersionOverride=$null;$script:contractFailCommand=$null
    $script:contractCalls=[Collections.Generic.List[object]]::new()
    function script:Invoke-NativeTool {
        param([string]$FilePath,[string[]]$Arguments,[int[]]$AcceptedExitCodes=@(0),[string]$WorkingDirectory,[int]$TimeoutSeconds,[string]$Operation,[hashtable]$DiagnosticScope)
        if ($Arguments.Count -eq 1 -and $Arguments[0] -ceq '--version') {
            if ($script:contractActual) { $result=& $script:contractRealNative -FilePath $script:contractCli -Arguments @('--version') -TimeoutSeconds 20 -Operation tool-version }
            else { $result=[pscustomobject]@{ExitCode=0;Stdout='3.94.0';Stderr=''} }
            if ($script:contractVersionOverride) { $result=[pscustomobject]@{ExitCode=0;Stdout=$script:contractVersionOverride;Stderr=''} }
            $script:contractCalls.Add(@{command='oci --version';case='version';exit_code=$result.ExitCode;stdout_class=$(if ($script:contractVersionOverride) {'SIMULATED_OTHER_VERSION'} else {'VERSION'});stderr_present=([bool]$result.Stderr)})
            return $result
        }
        $verb=$Arguments[([Array]::IndexOf($Arguments,'--cli-rc-file')+2)..($Arguments.Count-1)]
        $command=($verb -join ' ')
        $case=$script:contractOverride
        if (-not $case) {
            if ($script:contractFailCommand -and $command -like "$($script:contractFailCommand)*") { $case='exit403' }
            elseif ($command -like 'iam region-subscription list*') { $case='region-subscription' }
            elseif ($command -like 'iam compartment list*') { $case='compartment' }
            elseif ($command -like 'iam availability-domain list*') { $case='availability-domain' }
            else { $case='empty' }
        }
        if ($script:contractActual) {
            try { $result=& $script:contractRealNative -FilePath $script:contractPython -Arguments @($script:contractFixture,$case) -TimeoutSeconds $(if ($case -eq 'timeout') {1} else {30}) -Operation oci-read }
            catch {
                $safe=$_.Exception.Data['SafeDiagnostic']
                $script:contractCalls.Add(@{command=$command;case=$case;exit_code=$(if ($safe) {$safe.exit_code} else {-1});stdout_class='WITHHELD_ON_FAILURE';stderr_present=$true})
                throw
            }
        } else {
            $stdout=switch ($case) {
                'empty' {''};'empty-total-zero' {'{"opc-total-items":"0"}'};'empty-etag' {'{"etag":"fixture-etag"}'}
                'one' {'{"data":[{"id":"fixture-1"}]}'};'two' {'{"data":[{"id":"fixture-1"},{"id":"fixture-2"}]}'}
                'explicit-empty' {'{"data":[]}'};'region-subscription' {'{"data":[{"is-home-region":true,"region-name":"ap-seoul-1","status":"READY"}]}' }
                'compartment' {'{"data":[{"id":"ocid1.compartment.oc1..offline","lifecycle-state":"ACTIVE"}]}' }
                'availability-domain' {'{"data":[{"name":"AD-1"}]}' }
                'empty-next-page' {'{"opc-next-page":"fixture-next"}'};'empty-stderr' {''}
                'invalid-json' {'not-json'};'null-data' {'{"data":null}'};'nonarray-data' {'{"data":{"id":"fixture"}}'}
                'empty-array-json' {'[]'};'empty-object-json' {'{}'};'empty-list-total-one' {'{"data":[],"opc-total-items":"1"}'}
                'no-data-unknown-header' {'{"unexpected":"fixture"}'};'total-nonzero' {'{"opc-total-items":1}'};'get-no-data' {'{}'}
                default {''}
            }
            if ($case -in @('exit401','exit403','exit404','exit-other','timeout')) {
                $raw=if ($case -eq 'exit401') {'{"code":"NotAuthenticated","status":401,"message":"SECRET_FIXTURE"}'} elseif ($case -eq 'exit403') {'{"code":"NotAuthorized","status":403,"message":"SECRET_FIXTURE"}'} elseif ($case -eq 'exit404') {'{"code":"NotAuthorizedOrNotFound","status":404,"message":"SECRET_FIXTURE"}'} else {'SECRET_FIXTURE'}
                $safe=Get-SafeNativeDiagnostic -Stderr $raw -ExitCode $(if ($case -eq 'timeout') {-1} else {7}) -Tool oci -Operation oci-read -TimedOut:($case -eq 'timeout')
                $exception=[InvalidOperationException]::new("code=$($safe.code); exit=$($safe.exit_code)")
                $exception.Data['SafeDiagnostic']=$safe
                $script:contractCalls.Add(@{command=$command;case=$case;exit_code=$safe.exit_code;stdout_class='WITHHELD_ON_FAILURE';stderr_present=$true})
                throw $exception
            }
            $result=[pscustomobject]@{ExitCode=0;Stdout=$stdout;Stderr=$(if ($case -eq 'empty-stderr') {'WARNING: fixture'} else {''})}
        }
        $shape=if ($result.Stdout -ceq '') {'EMPTY'} elseif ($result.Stdout -match 'opc-total-items') {'HEADER_TOTAL'} elseif ($result.Stdout -match '"data"') {'DATA'} else {'OTHER'}
        $script:contractCalls.Add(@{command=$command;case=$case;exit_code=$result.ExitCode;stdout_class=$shape;stderr_present=([bool]$result.Stderr)})
        return $result
    }
} $RendererPythonPath $CliPath $fixture $native $actualRenderer

$identity=[pscustomobject]@{ConfigPath='offline-config';Profile='offline';Tenancy='ocid1.tenancy.oc1..offline'}
$region='ap-seoul-1'
$listArgs=@('compute','instance','list','--compartment-id','ocid1.compartment.oc1..offline','--all')
$results=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Select-Fixture([string]$Name,[string]$Version='') { & $module {param($case,$version) $script:contractOverride=$case;$script:contractVersionOverride=$version} $Name $Version }
function Case([string]$Name,[scriptblock]$Action,[string]$Kind='OFFLINE_CONTRACT') {
    & $Action
    $results.Add(@{name=$Name;status='PASS';kind=$Kind})
    Write-Host "PASS [$Kind]: $Name"
}
function Reject([string]$Name,[string]$Fixture,[string]$Pattern,[switch]$Get) {
    Case $Name {
        Select-Fixture $Fixture
        $caught=$null
        try { Invoke-OciJson -Identity $identity -Region $region -Arguments $(if ($Get) {@('compute','instance','get','--instance-id','ocid1.instance.oc1..offline')} else {$listArgs}) -List:(!$Get) | Out-Null } catch { $caught=$_ }
        Check ($null -ne $caught -and $caught.Exception.Message -match $Pattern) "Fail-closed contract missing: $Name"
        Check ($caught.Exception.Message -notmatch 'SECRET_FIXTURE') 'Native secret leaked'
    }
}

if ($actualRenderer) {
    $version=& $native -FilePath $CliPath -Arguments @('--version') -TimeoutSeconds 20 -Operation tool-version
    Check ($version.ExitCode -eq 0 -and $version.Stdout.Trim() -ceq '3.94.0') 'Installed OCI CLI renderer version must be 3.94.0'
    $versionText=$version.Stdout.Trim()
} else { $versionText='NOT_RUN: no installed renderer paths; fixed-output mock branch' }
foreach ($entry in @(@('empty',0),@('empty-total-zero',0),@('empty-etag',0),@('one',1),@('two',2),@('explicit-empty',0))) {
    $fixtureName=[string]$entry[0];$expected=[int]$entry[1]
    Case "list $fixtureName -> $expected" {
        Select-Fixture $fixtureName
        $items=@(Invoke-OciJson -Identity $identity -Region $region -Arguments $listArgs -List)
        Check ($items.Count -eq $expected) "Wrong list count: $fixtureName"
    } $(if ($fixtureName -eq 'explicit-empty') {'MOCK_EXPLICIT_JSON'} elseif ($actualRenderer) {'ACTUAL_CLI_RENDERER_SDK_FIXTURE'} else {'MOCK_RENDERED_OUTPUT'})
}
foreach ($case in @(
    @('401 authentication','exit401','NotAuthenticated'),@('403 authorization','exit403','NotAuthorized'),
    @('404 scope or region','exit404','NotAuthorizedOrNotFound'),
    @('nonzero other','exit-other','exit='),@('read timeout','timeout','TIMEOUT'),
    @('malformed JSON','invalid-json','OCI_JSON_INVALID'),@('null data','null-data','data 누락'),
    @('object instead of list','nonarray-data','배열'),@('pagination unfinished','empty-next-page','pagination'),
    @('JSON array without data','empty-array-json','data 누락'),@('empty JSON object','empty-object-json','HEADERS_INVALID'),
    @('empty data with nonzero total','empty-list-total-one','COUNT_INVALID'),
    @('unexpected header','no-data-unknown-header','HEADERS_INVALID'),@('nonzero total','total-nonzero','COUNT_INVALID'),
    @('warning on empty','empty-stderr','STDERR_UNCONFIRMED'),@('get missing data','get-no-data','data 누락')
)) { Reject $case[0] $case[1] $case[2] -Get:($case[0] -eq 'get missing data') }
Case 'wrong CLI version fails closed for empty stdout' {
    Select-Fixture 'empty' '3.95.0'
    $caught=$null;try { Invoke-OciJson -Identity $identity -Region $region -Arguments $listArgs -List | Out-Null } catch { $caught=$_ }
    Check ($caught.Exception.Message -match 'OCI_CLI_VERSION_UNSUPPORTED') 'Version gate bypassed'
} 'MOCK_VERSION_MISMATCH'
Case 'CLI output override environment cannot suppress data' {
    $old=[Environment]::GetEnvironmentVariable('OCI_CLI_QUERY')
    try { [Environment]::SetEnvironmentVariable('OCI_CLI_QUERY','SECRET_FIXTURE');Select-Fixture 'empty';$caught=$null;try { Invoke-OciJson -Identity $identity -Region $region -Arguments $listArgs -List | Out-Null } catch { $caught=$_ };Check ($caught.Exception.Message -match 'OCI_CLI_ENV_OVERRIDE' -and $caught.Exception.Message -notmatch 'SECRET_FIXTURE') 'Ambient override accepted' }
    finally { if ($null -eq $old) { Remove-Item Env:OCI_CLI_QUERY -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable('OCI_CLI_QUERY',$old) } }
} 'MOCK_UNSAFE_ENV'
Case 'all compartments resource lists pass through CLI renderer into inventory' {
    Select-Fixture ''
    $beforeCount=& $module { $script:contractCalls.Count }
    $config=@{region=$region;compartment_ocid='ocid1.compartment.oc1..offline'}
    $query={param($targetRegion,$arguments,$list) Invoke-OciJson -Identity $identity -Region $targetRegion -Arguments $arguments -List:$list}.GetNewClosure()
    $inventory=Get-AccountInventory -Identity $identity -Config $config -Query $query
    Check ($inventory.resources.Count -eq 0 -and $inventory.compartments.Count -eq 2 -and $inventory.home_region -eq $region) 'Inventory did not receive real rendered empty lists'
    $calls=@(& $module { $script:contractCalls.ToArray() } | Select-Object -Skip $beforeCount)
    $resourceCalls=@($calls | Where-Object { $_.command -match '^(compute instance|bv volume|bv boot-volume-backup|bv backup|mysql db-system|mysql backup|db autonomous-database|bv boot-volume) list' })
    Check ($resourceCalls.Count -eq 16 -and @($resourceCalls | Where-Object { $_.exit_code -ne 0 -or $_.stdout_class -ne 'EMPTY' }).Count -eq 0) 'Full resource inventory bypassed or failed renderer output'
} $(if ($actualRenderer) {'ACTUAL_CLI_RENDERER_TO_INVENTORY_SDK_FIXTURE'} else {'MOCK_OUTPUT_TO_INVENTORY'})
Case 'inventory stops on one permission failure after previous empty lists' {
    Select-Fixture ''
    & $module { $script:contractFailCommand='mysql backup list' }
    try {
        $config=@{region=$region;compartment_ocid='ocid1.compartment.oc1..offline'}
        $query={param($targetRegion,$arguments,$list) Invoke-OciJson -Identity $identity -Region $targetRegion -Arguments $arguments -List:$list}.GetNewClosure()
        $caught=$null;try { Get-AccountInventory -Identity $identity -Config $config -Query $query | Out-Null } catch { $caught=$_ }
        Check ($null -ne $caught -and $caught.Exception.Message -match 'NotAuthorized' -and $caught.Exception.Message -notmatch 'SECRET_FIXTURE') 'Inventory treated failed query as zero resources'
    } finally { & $module { $script:contractFailCommand=$null } }
} $(if ($actualRenderer) {'ACTUAL_CLI_RENDERER_PLUS_MOCK_PERMISSION_FAILURE'} else {'MOCK_OUTPUT_PLUS_PERMISSION_FAILURE'})

$calls=& $module { $script:contractCalls.ToArray() }
$summary=@{status='PASS';checked_at=[datetimeoffset]::UtcNow.ToString('o');installed_cli_version=$versionText;cli_command='oci --version';list_command='oci --config-file <fixture> --profile offline --auth api_key --region ap-seoul-1 --output json --cli-rc-file scripts/oci-cli-empty-rc.ini compute instance list --compartment-id <fixture> --all';renderer_process=$(if ($actualRenderer) {'installed OCI CLI cli_util.render_response via Python SDK-shaped fixture'} else {'NOT_RUN'});cases=@($results.ToArray());native_calls=@($calls | ForEach-Object { @{case=$_.case;command=$_.command;exit_code=$_.exit_code;stdout_class=$_.stdout_class;stderr_present=$_.stderr_present} });live_oci='NOT_RUN';state_or_account_changed=$false}
$summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $evidence 'oci-list-contract-results.json') -Encoding utf8
Write-Host "OCI LIST CONTRACT: $($results.Count) PASS; renderer=$(if ($actualRenderer) {'ACTUAL_CLI_3.94.0'} else {'NOT_RUN_MOCK_ONLY'}); live OCI NOT_RUN. Evidence: $evidence"
