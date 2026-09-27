#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'scripts/lib/Database.psm1'
Import-Module $modulePath -Force
$script:passed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Host "PASS [offline/mock]: $Name"
}
function Assert-True([bool]$Condition, [string]$Message = 'Assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern = '.') {
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    if ($null -eq $caught) { throw 'Expected an exception.' }
    if ($caught.Exception.Message -notmatch $Pattern) { throw "Exception did not match expected pattern: $Pattern" }
}
function Copy-Json($Object) { $Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
$definitions = Get-Content -LiteralPath (Join-Path $repoRoot 'examples/databases.json.example') -Raw | ConvertFrom-Json
$service = $definitions.databases[0]
$target = [pscustomobject]@{ environment = 'dev'; tenancy_ocid = 'ocid1.tenancy.oc1..offlineexample'; region = 'ap-osaka-1'; mysql_db_system_ocid = 'ocid1.mysqldbsystem.oc1.aposaka.offlineexample'; mysql_hostname = 'mysql.example.internal'; mysql_port = 13306; admin_username = 'dbadmin' }
$validGrants = @('GRANT USAGE ON *.* TO `translacat_ll_app`@`%`', 'GRANT SELECT, INSERT, UPDATE, DELETE ON `translacat_ll`.* TO `translacat_ll_app`@`%`')
Test-Case 'PowerShell syntax' {
    foreach ($relative in @('scripts/lib/Database.psm1', 'scripts/Bootstrap-Database.ps1', 'scripts/Verify-Database.ps1', 'tests/Test-Database.ps1')) {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $relative), [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "Parse error in $relative"
    }
}
Test-Case 'Example services and reviewed target accepted' { Assert-DatabaseDefinitions $definitions $target.admin_username; Assert-DatabaseTarget $target 'dev' }
Test-Case 'SQL injection identifier rejected' { $bad = Copy-Json $definitions; $bad.databases[0].name = 'db`; DROP DATABASE mysql'; Assert-Throws { Assert-DatabaseDefinitions $bad } }
Test-Case 'Reserved schema rejected' { $bad = Copy-Json $definitions; $bad.databases[0].name = 'mysql'; Assert-Throws { Assert-DatabaseDefinitions $bad } }
Test-Case 'Shared username rejected' { $bad = Copy-Json $definitions; $bad.databases[1].username = $bad.databases[0].username; Assert-Throws { Assert-DatabaseDefinitions $bad } }
Test-Case 'Administrator username rejected for app' { Assert-Throws { Assert-DatabaseDefinitions $definitions 'translacat_ll_app' } }
Test-Case 'SQL injection account host rejected' { $bad = Copy-Json $definitions; $bad.databases[0].host = "%' OR 1=1"; Assert-Throws { Assert-DatabaseDefinitions $bad } }
Test-Case 'Wrong environment rejected' { Assert-Throws { Assert-DatabaseTarget $target 'prod' } }
Test-Case 'TLS localhost fallback rejected' { $bad = Copy-Json $target; $bad.mysql_hostname = '127.0.0.1'; Assert-Throws { Assert-DatabaseTarget $bad 'dev' } }
Test-Case 'Explicit VERIFY_CA permits private SSH tunnel but not public IP' {
    $explicit = Copy-Json $target; $explicit.mysql_hostname = '127.0.0.1'
    Assert-DatabaseTarget $explicit 'dev' 'VERIFY_CA'
    $explicit.mysql_hostname = '203.0.113.1'
    Assert-Throws { Assert-DatabaseTarget $explicit 'dev' 'VERIFY_CA' }
}
Test-Case 'VERIFY_CA requires independently matched SHA256' {
    $hash = 'AB' * 32
    Assert-DatabaseCaPin 'VERIFY_CA' $hash $hash
    Assert-Throws { Assert-DatabaseCaPin 'VERIFY_CA' '' $hash }
    Assert-Throws { Assert-DatabaseCaPin 'VERIFY_CA' ('CD' * 32) $hash }
    Assert-Throws { New-MySqlProcessStartInfo 'mysql' 'client.cnf' $target $service.username 'ca.pem' 'DISABLED' }
}
Test-Case 'SQL quotes and backslashes preserved under explicit SQL mode' {
    Assert-True ((ConvertTo-MySqlLiteral "a'b\c") -ceq "'a''b\c'")
    Assert-Throws { ConvertTo-MySqlLiteral "a`nb" }
}
Test-Case 'Option values escape quotes and backslashes without new lines' {
    Assert-True ((ConvertTo-MySqlOptionValue 'a"b\c#d') -ceq '"a\"b\\c#d"')
    Assert-Throws { ConvertTo-MySqlOptionValue "bad`n[mysql]" }
}
Test-Case 'Create SQL is idempotent and non-destructive' {
    $secret = ConvertTo-SecureString "TestOnly!Pass'word\2026" -AsPlainText -Force
    try {
        $sql = (New-CreateDatabaseSql $service) + (New-CreateDatabaseUserSql $service $secret) + (New-GrantDatabaseSql $service)
        Assert-True ($sql -match 'CREATE DATABASE IF NOT EXISTS' -and $sql -match 'CREATE USER IF NOT EXISTS' -and $sql -match 'SELECT @@warning_count')
        Assert-True ($sql -notmatch '\b(DROP|TRUNCATE|ALTER USER|GRANT ALL|WITH GRANT OPTION)\b')
        Assert-True ($sql.Contains("'TestOnly!Pass''word\2026'"))
        Assert-True ($sql.Contains('REQUIRE SSL'))
    } finally { $secret.Dispose(); $sql = $null }
}
Test-Case 'Weak new password rejected' { $secret = ConvertTo-SecureString 'weak' -AsPlainText -Force; try { Assert-Throws { New-CreateDatabaseUserSql $service $secret } } finally { $secret.Dispose() } }
Test-Case 'Exact DML grants accepted' { Assert-DatabaseGrantRows $service $validGrants }
Test-Case 'Global grants rejected' { Assert-Throws { Assert-DatabaseGrantRows $service @('GRANT SELECT ON *.* TO `translacat_ll_app`@`%`') } }
Test-Case 'Peer schema grants rejected' { Assert-Throws { Assert-DatabaseGrantRows $service @('GRANT SELECT, INSERT, UPDATE, DELETE ON `translacat_chat`.* TO `translacat_ll_app`@`%`') } }
Test-Case 'Roles and grant option rejected' {
    Assert-Throws { Assert-DatabaseGrantRows $service ($validGrants + 'GRANT `administrator`@`%` TO `translacat_ll_app`@`%`') }
    Assert-Throws { Assert-DatabaseGrantRows $service @('GRANT SELECT, INSERT, UPDATE, DELETE ON `translacat_ll`.* TO `translacat_ll_app`@`%` WITH GRANT OPTION') }
}
Test-Case 'Missing DML privileges fail without repair' { Assert-Throws { Assert-DatabaseGrantRows $service @('GRANT SELECT ON `translacat_ll`.* TO `translacat_ll_app`@`%`') } }
Test-Case 'TLS cipher positive and negative' { Assert-MySqlTlsResult "Ssl_cipher`tTLS_AES_256_GCM_SHA384"; Assert-Throws { Assert-MySqlTlsResult "Ssl_cipher`t" } }
Test-Case 'Peer denial must be specifically 1044' {
    Assert-MySqlDeniedResult ([pscustomobject]@{ ExitCode = 1; ErrorNumber = 1044 })
    Assert-Throws { Assert-MySqlDeniedResult ([pscustomobject]@{ ExitCode = 0; ErrorNumber = $null }) }
    Assert-Throws { Assert-MySqlDeniedResult ([pscustomobject]@{ ExitCode = 1; ErrorNumber = 2003 }) }
    Assert-Throws { Assert-MySqlDeniedResult ([pscustomobject]@{ ExitCode = 1; ErrorNumber = 1049 }) }
}
Test-Case 'Process receives TLS flags and no SQL/password arguments' {
    $start = New-MySqlProcessStartInfo 'mysql' 'C:/private/client.cnf' $target $service.username 'C:/private/ca.pem'
    Assert-True ($start.ArgumentList[0] -eq '--defaults-file=C:/private/client.cnf')
    Assert-True ($start.ArgumentList.Contains('--ssl-mode=VERIFY_IDENTITY') -and $start.ArgumentList.Contains('--no-login-paths'))
    Assert-True ($start.ArgumentList.Contains('--host=mysql.example.internal') -and $start.ArgumentList.Contains('--port=13306'))
    Assert-True (-not (($start.ArgumentList -join ' ') -match '--password|--execute|SELECT|CREATE'))
    Assert-True (-not $start.UseShellExecute -and $start.RedirectStandardInput -and $start.CreateNoWindow)
}
Test-Case 'Actual local subprocess exit/error parsing suppresses secret stderr (no MySQL)' {
    $start = New-MySqlProcessStartInfo (Get-Process -Id $PID).Path 'unused' $target $service.username 'unused'
    $start.ArgumentList.Clear()
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-Command', '[void][Console]::In.ReadToEnd(); [Console]::Error.WriteLine("ERROR 1045 (28000): SyntheticSecretMustNotEscape"); exit 7')) { $start.ArgumentList.Add($arg) }
    $result = Invoke-MySqlClientProcess $start 'SELECT 1;'
    Assert-True ($result.ExitCode -eq 7 -and $result.ErrorNumber -eq 1045)
    Assert-True (($result | ConvertTo-Json -Compress) -notmatch 'SyntheticSecretMustNotEscape')
}

# These mocks execute the production orchestrator and secret-file wrapper, but never start mysql or contact a database.
$module = Get-Module Database
& $module {
    $script:mockQueries = [Collections.Generic.List[string]]::new()
    $script:mockUserExists = $false
    $script:mockCreateWarnings = '0'
    function script:Invoke-MySqlQuery {
        param($Target, $Username, $Password, $Sql, $CaPath, $LocalDirectory, $MySqlPath, [switch]$AllowFailure)
        $script:mockQueries.Add($Sql)
        $output = ''
        if ($Sql -match 'SELECT COUNT\(\*\) FROM mysql.user') { $output = $(if ($script:mockUserExists) { '1' } else { '0' }) }
        elseif ($Sql -match 'CREATE USER') { $script:mockUserExists = $true; $output = $script:mockCreateWarnings }
        elseif ($Sql -match 'SHOW GRANTS') { $output = 'GRANT USAGE ON *.* TO `translacat_ll_app`@`%`' + "`n" + 'GRANT SELECT, INSERT, UPDATE, DELETE ON `translacat_ll`.* TO `translacat_ll_app`@`%`' }
        elseif ($Sql -match 'SELECT ssl_type') { $output = 'ANY' }
        [pscustomobject]@{ ExitCode = 0; Output = $output; ErrorNumber = $null }
    }
}
$oneDefinition = [pscustomobject]@{ databases = @($service) }
$adminArgs = @{ Target = $target }
$readTestPassword = { param($Name) ConvertTo-SecureString 'OnlyForMock!2026' -AsPlainText -Force }
Test-Case 'Missing approval executes no SQL' {
    Assert-Throws { Invoke-ApprovedDatabaseBootstrap -Definitions $oneDefinition -ExistingUsers @{ translacat_ll_app = $false } -AdminArguments $adminArgs -Confirmation 'no' -ReadNewPassword $readTestPassword }
    Assert-True ((& $module { $script:mockQueries.Count }) -eq 0)
}
Test-Case 'First bootstrap creates database, user and own grants (mock)' {
    Invoke-ApprovedDatabaseBootstrap -Definitions $oneDefinition -ExistingUsers @{ translacat_ll_app = $false } -AdminArguments $adminArgs -Confirmation "BOOTSTRAP $($target.mysql_db_system_ocid)" -ReadNewPassword $readTestPassword
    $queries = & $module { $script:mockQueries.ToArray() }
    Assert-True (@($queries | Where-Object { $_ -match 'CREATE USER' }).Count -eq 1)
    Assert-True (@($queries | Where-Object { $_ -match '^SET[^;]+;\s*GRANT SELECT' }).Count -eq 1)
}
Test-Case 'Rerun preserves account password and grants (mock)' {
    & $module { $script:mockQueries.Clear() }
    $exists = Get-DatabaseAccountState $service $adminArgs
    Assert-True $exists
    Invoke-ApprovedDatabaseBootstrap -Definitions $oneDefinition -ExistingUsers @{ translacat_ll_app = $exists } -AdminArguments $adminArgs -Confirmation "BOOTSTRAP $($target.mysql_db_system_ocid)" -ReadNewPassword { throw 'Password prompt must not run for an existing user.' }
    $queries = & $module { $script:mockQueries.ToArray() }
    Assert-True (-not (($queries -join "`n") -match '\b(CREATE USER|ALTER USER|DROP|TRUNCATE)\b|(?m)^GRANT '))
}
Test-Case 'Concurrent existing user warning prevents new grant (mock)' {
    & $module { $script:mockQueries.Clear(); $script:mockCreateWarnings = '1' }
    Assert-Throws { Invoke-ApprovedDatabaseBootstrap -Definitions $oneDefinition -ExistingUsers @{ translacat_ll_app = $false } -AdminArguments $adminArgs -Confirmation "BOOTSTRAP $($target.mysql_db_system_ocid)" -ReadNewPassword $readTestPassword } 'warning'
    $queries = & $module { $script:mockQueries.ToArray() }
    Assert-True (-not (($queries -join "`n") -match '(?m)^GRANT '))
}
Remove-Module Database
Import-Module $modulePath -Force
$module = Get-Module Database
if (-not $ScratchRoot) { $ScratchRoot = Join-Path $repoRoot '.local/validation/database-tests' }
[void][IO.Directory]::CreateDirectory($ScratchRoot)
$mockSecret = ConvertTo-SecureString 'SyntheticOnly!a"b\2026' -AsPlainText -Force
& $module {
    $script:seenOptionsFile = $null
    $script:mockNativeExit = 0
    function script:Invoke-MySqlClientProcess {
        param($StartInfo, $Sql)
        $path = $StartInfo.ArgumentList[0].Substring('--defaults-file='.Length)
        $script:seenOptionsFile = $path
        if (-not (Test-Path -LiteralPath $path)) { throw 'Credential fixture not created.' }
        if ((Get-Content -LiteralPath $path -Raw) -cne "[client]`npassword=`"SyntheticOnly!a\`"b\\2026`"`n") { throw 'Option file did not preserve the synthetic password.' }
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath (Split-Path $path -Parent)
            if (-not $acl.AreAccessRulesProtected -or @($acl.Access).Count -ne 1) { throw 'Temp credentials directory ACL is not restricted.' }
        }
        [pscustomobject]@{ ExitCode = $script:mockNativeExit; Output = '1'; ErrorNumber = $(if ($script:mockNativeExit) { 1045 } else { $null }) }
    }
}
try {
    $wrapperArgs = @{ Target = $target; Username = $service.username; Password = $mockSecret; Sql = 'SELECT 1;'; CaPath = 'unused-mock-ca.pem'; LocalDirectory = $ScratchRoot; MySqlPath = (Get-Process -Id $PID).Path }
    Test-Case 'Protected credential file and stdin process boundary; successful cleanup (mock native)' {
        $result = Invoke-MySqlQuery @wrapperArgs
        Assert-True ($result.ExitCode -eq 0)
        $optionPath = & $module { $script:seenOptionsFile }
        Assert-True (-not (Test-Path -LiteralPath $optionPath) -and -not (Test-Path -LiteralPath (Split-Path $optionPath -Parent)))
    }
    Test-Case 'Native error fails closed, masks secret and cleans credentials (mock native)' {
        & $module { $script:mockNativeExit = 1 }
        Assert-Throws { Invoke-MySqlQuery @wrapperArgs } 'exit 1, MySQL error 1045'
        $optionPath = & $module { $script:seenOptionsFile }
        Assert-True (-not (Test-Path -LiteralPath $optionPath))
    }
} finally { $mockSecret.Dispose(); Remove-Module Database; Import-Module $modulePath -Force }
Write-Host "DATABASE TESTS: $script:passed passed (offline/mock). Live OCI/MySQL/bootstrap/driver/migration tests: NOT RUN."
