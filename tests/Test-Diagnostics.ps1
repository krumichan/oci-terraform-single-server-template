#requires -Version 7.2
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/lib/Common.psm1') -Force -DisableNameChecking
$script:count=0
function Case([string]$Name,[scriptblock]$Action) { & $Action;$script:count++;Write-Host "PASS [diagnostic/local]: $Name" }
function Check([bool]$Value,[string]$Reason) { if (-not $Value) {throw $Reason} }
$secret='NeverPrint-Password-Sql-State-Key!'
$trace=('A'*32)+'/'+('B'*32)+'/'+('C'*32)
Case 'OCI code/status/hex request ID allowlist only' {
    $raw=@{code='NotAuthenticated';status=401;'opc-request-id'=$trace;message=$secret;request_body=@{password=$secret};private_key=$secret} | ConvertTo-Json -Depth 8
    $d=Get-SafeNativeDiagnostic -Stderr $raw -Stdout $secret -ExitCode 1 -Tool oci -Operation oci-read -Scope @{region='ap-seoul-1';compartment_id='ocid1.compartment.oc1..fixture';password=$secret}
    Check ($d.code -eq 'NotAuthenticated' -and $d.http_status -eq 401 -and $d.request_id -eq $trace) 'OCI diagnostic missing'
    Check (($d | ConvertTo-Json -Depth 10) -notmatch [regex]::Escape($secret)) 'response secret leaked'
}
foreach ($code in @('NotAuthorizedOrNotFound','RelatedResourceNotAuthorizedOrNotFound','LimitExceeded','QuotaExceeded','InvalidParameter','TooManyRequests','InternalServerError')) {
    Case "Oracle error category $code" { $d=Get-SafeNativeDiagnostic -Stderr ('{"code":"'+$code+'","message":"'+$secret+'"}') -ExitCode 1;Check ($d.code -eq $code -and $d.action -notmatch [regex]::Escape($secret)) 'wrong safe class' }
}
Case 'arbitrary code/request ID/message never reflected' {
    $d=Get-SafeNativeDiagnostic -Stderr ('{"code":"'+$secret+'","opc-request-id":"'+$secret+'","message":"'+$secret+'"}') -ExitCode 4 -Tool $secret -Operation $secret -Scope @{region=$secret;compartment_id=$secret}
    Check ($d.code -eq 'UNKNOWN' -and $null -eq $d.request_id -and $d.scope.Count -eq 0) 'unsafe response fields retained'
    Check (($d | ConvertTo-Json) -notmatch [regex]::Escape($secret)) 'secret in diagnostic'
}
Case 'stderr multiline PEM SQL and state remain private' {
    $raw="-----BEGIN PRIVATE KEY-----`n$secret`n-----END PRIVATE KEY-----`nCREATE USER app IDENTIFIED BY '$secret';`n{state: '$secret'}"
    $d=Get-SafeNativeDiagnostic -Stderr $raw -ExitCode 1
    Check (($d | ConvertTo-Json) -notmatch 'BEGIN PRIVATE|CREATE USER|state:|NeverPrint') 'raw body was exposed'
}
foreach ($pair in @(
    @('REMOTE HOST IDENTIFICATION HAS CHANGED','SSH_HOST_KEY_MISMATCH'),
    @('Host key verification failed','SSH_HOST_KEY_UNKNOWN'),
    @('Permission denied (publickey).','SSH_PUBLICKEY'),
    @('Could not open a connection to your authentication agent.','SSH_AGENT_UNAVAILABLE'),
    @('Connection timed out','CONNECTION_TIMEOUT'),
    @('CERTIFICATE_VERIFY_FAILED','TLS_VERIFICATION'),
    @('Error: 404-NotAuthorizedOrNotFound','NotAuthorizedOrNotFound'),
    @('Error acquiring the state lock','TF_STATE_LOCK'),
    @('Saved plan is stale','TF_STALE_PLAN'),
    @('lifecycle.prevent_destroy','TF_PREVENT_DESTROY'),
    @('Failed to query available provider packages','TF_REGISTRY'),
    @('Out of host capacity','OutOfHostCapacity')
)) { Case "static cause $($pair[1])" { $d=Get-SafeNativeDiagnostic -Stderr ($pair[0]+"`n"+$secret) -ExitCode 1;Check ($d.code -eq $pair[1]) 'unexpected cause' } }
Case 'certificate VM missing tool gives safe action' {
    $d=Get-SafeNativeDiagnostic -ExitCode 126 -Operation certificate-read -Stderr $secret
    Check ($d.code -eq 'CERT_VM_TOOL_MISSING' -and $d.action -match 'OpenSSL') 'missing remote tool not diagnosed'
}
Case 'remote certificate read timeout classified' {
    $d=Get-SafeNativeDiagnostic -ExitCode 124 -Operation certificate-read
    Check ($d.code -eq 'TIMEOUT') 'remote timeout not diagnosed'
}
Case 'real local subprocess redacts exception and structured Data' {
    $payload='[Console]::Error.WriteLine(''{"code":"NotAuthenticated","status":401,"password":"'+$secret+'"}'');exit 7'
    $caught=$null
    try { Invoke-NativeTool -FilePath (Get-Process -Id $PID).Path -Arguments @('-NoProfile','-Command',$payload) -Operation offline-test | Out-Null } catch { $caught=$_ }
    Check ($null -ne $caught -and $caught.Exception.Message -match 'exit=7' -and $caught.Exception.Message -match 'NotAuthenticated') 'safe native error missing'
    Check (($caught | Out-String) -notmatch [regex]::Escape($secret)) 'exception leaked secret'
    Check (($caught.Exception.Data.SafeDiagnostic | ConvertTo-Json -Depth 10) -notmatch [regex]::Escape($secret)) 'structured error leaked'
}
Case 'real local read timeout terminates without retry' {
    $watch=[Diagnostics.Stopwatch]::StartNew();$caught=$null
    try { Invoke-NativeTool -FilePath (Get-Process -Id $PID).Path -Arguments @('-NoProfile','-Command','Start-Sleep -Seconds 20') -TimeoutSeconds 1 -Operation ssh-check | Out-Null } catch { $caught=$_ }
    $watch.Stop()
    Check ($caught.Exception.Message -match 'code=TIMEOUT' -and $watch.Elapsed.TotalSeconds -lt 10) 'timeout was not enforced'
}
Case 'OCI malformed JSON is masked' {
    $module=Get-Module Common
    & $module { function script:Invoke-NativeTool { [pscustomobject]@{Stdout='BROKEN SECRET_JSON_SENTINEL';ExitCode=0} } }
    $caught=$null
    try { Invoke-OciJson -Identity ([pscustomobject]@{ConfigPath='fixture';Profile='fixture'}) -Region ap-seoul-1 -Arguments @('get') | Out-Null } catch { $caught=$_ }
    Check ($caught.Exception.Message -match 'OCI_JSON_INVALID' -and $caught.Exception.Message -notmatch 'SECRET_JSON_SENTINEL') 'invalid JSON leaked'
    Import-Module (Join-Path $PSScriptRoot '../scripts/lib/Common.psm1') -Force -DisableNameChecking
}
Case 'OCI unexpected native exception is masked' {
    $module=Get-Module Common
    & $module { function script:Invoke-NativeTool { throw 'SECRET_UNEXPECTED_EXCEPTION_SENTINEL' } }
    $caught=$null
    try { Invoke-OciJson -Identity ([pscustomobject]@{ConfigPath='fixture';Profile='fixture'}) -Region ap-seoul-1 -Arguments @('get') | Out-Null } catch { $caught=$_ }
    Check ($caught.Exception.Message -match 'code=UNKNOWN' -and $caught.Exception.Message -notmatch 'SECRET_UNEXPECTED_EXCEPTION_SENTINEL') 'unexpected exception leaked'
    Check ($null -ne $caught.Exception.Data.SafeDiagnostic) 'structured safe diagnostic missing'
    Import-Module (Join-Path $PSScriptRoot '../scripts/lib/Common.psm1') -Force -DisableNameChecking
}
Case 'long mutation has no default timeout or automatic retry' {
    $command=Get-Command Invoke-NativeTool
    $source=$command.ScriptBlock.ToString()
    Check ($source -match 'TimeoutSeconds=0' -and $source -match 'Apply/Destroy' -and $source -notmatch '(?i)auto-approve|retry\s*\(') 'mutation timeout/retry contract changed'
}
Write-Host "DIAGNOSTIC TESTS: $script:count PASS. Actual local processes only; OCI/SSH/live mutations NOT_RUN."
