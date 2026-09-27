#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-DatabaseDefinitions {
    param([Parameter(Mandatory)]$Definitions, [string]$AdminUsername)
    $items = @($Definitions.databases)
    if ($items.Count -lt 1 -or $items.Count -gt 20) { throw 'databases must contain 1..20 service definitions.' }
    $names = @{}; $users = @{}
    foreach ($item in $items) {
        if ($item.name -cnotmatch '^[a-z][a-z0-9_]{0,63}$' -or $item.name -in @('mysql', 'sys', 'information_schema', 'performance_schema')) {
            throw 'Database names must be lowercase SQL identifiers, at most 64 characters, excluding system schemas.'
        }
        if ($item.username -cnotmatch '^[a-z][a-z0-9_]{0,31}$' -or $item.username -in @('root', 'mysql', 'administrator', $AdminUsername)) {
            throw 'Each service needs a dedicated non-administrator username of at most 32 lowercase characters.'
        }
        if ($item.host -ne '%' -and $item.host -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,3}(\.\d{1,3}){3})?$') {
            throw 'Account host must be % or an explicitly reviewed IPv4 address/netmask.'
        }
        if ($item.host -ne '%') {
            foreach ($part in ($item.host -split '/')) {
                $ip = $null
                if (-not [System.Net.IPAddress]::TryParse($part, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { throw 'Invalid account host IPv4 address/netmask.' }
            }
        }
        if ($names.ContainsKey($item.name) -or $users.ContainsKey($item.username)) { throw 'Database names and service usernames must each be unique.' }
        $names[$item.name] = $true; $users[$item.username] = $true
    }
}

function Assert-DatabaseTarget {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][string]$Environment, [ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode = 'VERIFY_IDENTITY')
    if ($Environment -cnotmatch '^[a-z][a-z0-9-]{0,31}$' -or $Target.environment -cne $Environment) { throw 'Database target environment does not match the selected environment.' }
    if ($Target.tenancy_ocid -notmatch '^ocid1\.tenancy\.[A-Za-z0-9.-]+$') { throw 'A reviewed tenancy OCID is required.' }
    if ($Target.mysql_db_system_ocid -notmatch '^ocid1\.mysqldbsystem\.[A-Za-z0-9.-]+$') { throw 'A reviewed MySQL DB System OCID is required.' }
    if ($Target.region -cnotmatch '^[a-z]{2,3}-[a-z0-9-]+-[1-9][0-9]*$') { throw 'A reviewed OCI region is required.' }
    if ($Target.mysql_hostname -cnotmatch '^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$') { throw 'Invalid reviewed DB hostname.' }
    if ($TlsMode -eq 'VERIFY_IDENTITY' -and ($Target.mysql_hostname -notmatch '[a-zA-Z]' -or $Target.mysql_hostname -in @('localhost', 'localhost.localdomain'))) {
        throw 'VERIFY_IDENTITY requires the reviewed certificate-covered DB hostname, never localhost or an IP fallback.'
    }
    if ($TlsMode -eq 'VERIFY_CA' -and $Target.mysql_hostname -notmatch '[a-zA-Z]') {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($Target.mysql_hostname, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork') { throw 'Invalid private/tunnel IPv4 endpoint.' }
        $bytes = $ip.GetAddressBytes()
        if (-not ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or $Target.mysql_hostname -eq '127.0.0.1')) { throw 'MySQL must use a private endpoint or authenticated SSH loopback tunnel.' }
    }
    if ([int]$Target.mysql_port -lt 1 -or [int]$Target.mysql_port -gt 65535) { throw 'Invalid MySQL port.' }
    if ($Target.admin_username -cnotmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$') { throw 'Invalid MySQL administrator username.' }
}

function Read-DatabaseInputs {
    param([string]$TargetPath, [string]$DefinitionsPath, [string]$Environment, [string]$CaPath, [ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode = 'VERIFY_IDENTITY', [string]$ExpectedCaFileSha256)
    $target = Get-Content -LiteralPath $TargetPath -Raw | ConvertFrom-Json
    $definitions = Get-Content -LiteralPath $DefinitionsPath -Raw | ConvertFrom-Json
    Assert-DatabaseTarget $target $Environment $TlsMode
    Assert-DatabaseDefinitions $definitions $target.admin_username
    if (-not (Test-Path -LiteralPath $CaPath -PathType Leaf)) { throw 'A CA PEM file from a trusted OCI/certificate source is required. Do not disable TLS verification.' }
    $caFullPath = (Resolve-Path -LiteralPath $CaPath).Path
    if ((Get-Content -LiteralPath $caFullPath -Raw) -notmatch '-----BEGIN CERTIFICATE-----') { throw 'The CA file must contain a PEM certificate.' }
    $actualCaHash = (Get-FileHash -LiteralPath $caFullPath -Algorithm SHA256).Hash
    Assert-DatabaseCaPin $TlsMode $ExpectedCaFileSha256 $actualCaHash
    [pscustomobject]@{ Target = $target; Definitions = $definitions; CaPath = $caFullPath; CaFileSha256 = $actualCaHash }
}

function Assert-DatabaseCaPin {
    param([ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode, [string]$ExpectedCaFileSha256, [string]$ActualCaFileSha256)
    if ($TlsMode -eq 'VERIFY_CA' -and ($ExpectedCaFileSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $ActualCaFileSha256 -ine $ExpectedCaFileSha256)) {
        throw 'VERIFY_CA requires -ExpectedCaFileSha256 matching this PEM file, independently confirmed through an already trusted SSH/OCI route. No automatic TLS downgrade is allowed.'
    }
}

function Confirm-DatabaseCertificateTrust {
    param([ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode, [string]$CaFileSha256)
    if ($TlsMode -ne 'VERIFY_CA') { return }
    Write-Host 'VERIFY_CA: 인증서 검증과 암호화는 유지하지만 hostname 일치는 확인하지 않습니다.'
    Write-Host '이미 host key를 검증한 SSH/OCI 경로에서 대상 DB 인증서를 수집하고 PEM 파일 SHA256을 독립 비교한 경우에만 승인하세요.'
    Write-Host "Pinned PEM file SHA256: $CaFileSha256"
    $phrase = "TRUST CERTIFICATE $CaFileSha256"
    if ((Read-Host "이 인증서 신뢰를 승인하려면 정확히 입력하세요: $phrase") -cne $phrase) { throw 'Certificate trust was not approved; no database connection was attempted.' }
}

function ConvertTo-MySqlLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '[\x00-\x1f\x7f]') { throw 'Control characters are not allowed in SQL values.' }
    # Every generated SQL batch starts with NO_BACKSLASH_ESCAPES, making quote doubling unambiguous.
    "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-MySqlOptionValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '[\x00-\x1f\x7f]') { throw 'Control characters are not allowed in MySQL options.' }
    '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-DatabaseAccountSql {
    param([Parameter(Mandatory)]$Definition)
    (ConvertTo-MySqlLiteral $Definition.username) + '@' + (ConvertTo-MySqlLiteral $Definition.host)
}

function Get-DatabaseSqlPrefix { "SET SESSION sql_mode = 'NO_BACKSLASH_ESCAPES';`n" }

function New-CreateDatabaseSql {
    param([Parameter(Mandatory)]$Definition)
    Assert-DatabaseDefinitions ([pscustomobject]@{ databases = @($Definition) })
    (Get-DatabaseSqlPrefix) + ('CREATE DATABASE IF NOT EXISTS `{0}` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;' -f $Definition.name)
}

function New-CreateDatabaseUserSql {
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][securestring]$Password)
    Assert-DatabaseDefinitions ([pscustomobject]@{ databases = @($Definition) })
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        if ($plain.Length -lt 16 -or $plain.Length -gt 128 -or $plain -cnotmatch '[a-z]' -or $plain -cnotmatch '[A-Z]' -or $plain -notmatch '[0-9]' -or $plain -notmatch '[^A-Za-z0-9]') {
            throw 'New service passwords need 16..128 characters, uppercase/lowercase, a digit and a symbol. OCI may apply additional policy.'
        }
        $account = Get-DatabaseAccountSql $Definition
        (Get-DatabaseSqlPrefix) + "CREATE USER IF NOT EXISTS $account IDENTIFIED BY $(ConvertTo-MySqlLiteral $plain) REQUIRE SSL;`nSELECT @@warning_count;"
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        $plain = $null
    }
}

function New-GrantDatabaseSql {
    param([Parameter(Mandatory)]$Definition)
    Assert-DatabaseDefinitions ([pscustomobject]@{ databases = @($Definition) })
    # The caller MUST prove @@GLOBAL.partial_revokes=1 first, so underscores are literal.
    (Get-DatabaseSqlPrefix) + ('GRANT SELECT, INSERT, UPDATE, DELETE ON `{0}`.* TO {1};' -f $Definition.name, (Get-DatabaseAccountSql $Definition))
}

function Assert-DatabaseGrantRows {
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string[]]$Rows)
    $accountPattern = '[`''"]' + [regex]::Escape($Definition.username) + '[`''"]@[`''"]' + [regex]::Escape($Definition.host) + '[`''"]'
    $scopePattern = '`' + [regex]::Escape($Definition.name) + '`\.\*'
    $actual = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) {
        if ($row -match ('^GRANT USAGE ON \*\.\* TO ' + $accountPattern + '$')) { continue }
        if ($row -notmatch ('^GRANT (?<privileges>[A-Z, ]+) ON ' + $scopePattern + ' TO ' + $accountPattern + '$')) {
            throw 'Unexpected global, cross-schema, role, proxy or grant-option privilege. Existing account is preserved; review its privileges separately.'
        }
        foreach ($privilege in ($Matches.privileges -split ',\s*')) {
            if ($privilege -cnotin @('SELECT', 'INSERT', 'UPDATE', 'DELETE')) { throw 'Unexpected service privilege. Existing grants were not changed.' }
            [void]$actual.Add($privilege)
        }
    }
    if ($actual.Count -ne 4) { throw 'The service account does not have the expected four DML privileges. Existing grants were not changed; approve any repair separately.' }
}

function New-PrivateDatabaseTempDirectory {
    param([Parameter(Mandatory)][string]$LocalDirectory)
    $parent = [IO.Directory]::CreateDirectory($LocalDirectory).FullName
    $path = Join-Path $parent ('mysql-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    try {
        if ($IsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetOwner($identity)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $path -AclObject $acl
        } else {
            [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        return $path
    } catch {
        # This exact empty directory was created here; no existing file is removed.
        [IO.Directory]::Delete($path, $false)
        throw 'Could not restrict permissions on the temporary credentials directory.'
    }
}

function New-MySqlProcessStartInfo {
    param([string]$MySqlPath, [string]$OptionFile, $Target, [string]$Username, [string]$CaPath, [ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode = 'VERIFY_IDENTITY')
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $MySqlPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    # --defaults-file is deliberately first; other ambient configuration and login paths cannot override the reviewed target.
    foreach ($argument in @("--defaults-file=$OptionFile", '--no-login-paths', '--batch', '--raw', '--skip-column-names', '--binary-mode', '--skip-reconnect', '--skip-force', '--skip-auto-rehash', '--local-infile=0', '--connect-timeout=10', '--default-character-set=utf8mb4', '--protocol=TCP', "--ssl-mode=$TlsMode", '--tls-version=TLSv1.2,TLSv1.3', "--ssl-ca=$CaPath", "--host=$($Target.mysql_hostname)", "--port=$($Target.mysql_port)", "--user=$Username")) {
        [void]$start.ArgumentList.Add($argument)
    }
    [void]$start.Environment.Remove('MYSQL_PWD')
    [void]$start.Environment.Remove('MYSQL_TEST_LOGIN_FILE')
    return $start
}

function Invoke-MySqlClientProcess {
    param([Diagnostics.ProcessStartInfo]$StartInfo, [string]$Sql)
    $process = [Diagnostics.Process]::new()
    $started = $false
    try {
        $process.StartInfo = $StartInfo
        $started = $process.Start()
        if (-not $started) { throw 'Could not start MySQL client.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($Sql)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true); $process.WaitForExit()
            throw 'MySQL query timed out after 60 seconds. No retry was performed; review any partially completed bootstrap.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $errorNumber = $null
        if ($stderr -match '(?m)^ERROR\s+(\d+)\b') { $errorNumber = [int]$Matches[1] }
        # Neither stderr nor a rejected secret-bearing SQL statement leaves this boundary.
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.TrimEnd("`r", "`n"); ErrorNumber = $errorNumber }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Invoke-MySqlQuery {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][string]$CaPath,
        [Parameter(Mandatory)][string]$LocalDirectory,
        [string]$MySqlPath = 'mysql',
        [ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode = 'VERIFY_IDENTITY',
        [switch]$AllowFailure
    )
    $tempDirectory = $null; $optionFile = $null; $ptr = [IntPtr]::Zero
    try {
        $resolvedCommand = Get-Command $MySqlPath -CommandType Application -ErrorAction Stop
        $tempDirectory = New-PrivateDatabaseTempDirectory $LocalDirectory
        $optionFile = Join-Path $tempDirectory 'client.cnf'
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        [IO.File]::WriteAllText($optionFile, "[client]`npassword=$(ConvertTo-MySqlOptionValue $plain)`n", [Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($optionFile, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr); $ptr = [IntPtr]::Zero; $plain = $null
        $startInfo = New-MySqlProcessStartInfo $resolvedCommand.Source $optionFile $Target $Username $CaPath $TlsMode
        $result = Invoke-MySqlClientProcess $startInfo $Sql
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            # Raw stderr may contain a rejected SQL statement/password. Never emit it or write a log.
            throw "MySQL client failed (exit $($result.ExitCode), MySQL error $($result.ErrorNumber)). Check TLS CA/hostname, tunnel, credentials and privileges; secret-bearing diagnostics are suppressed."
        }
        return $result
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        $plain = $null; $Sql = $null
        if ($optionFile -and (Test-Path -LiteralPath $optionFile)) { Remove-Item -LiteralPath $optionFile -Force }
        if ($tempDirectory -and (Test-Path -LiteralPath $tempDirectory)) { [IO.Directory]::Delete($tempDirectory, $false) }
    }
}

function Assert-MySqlTlsResult {
    param([Parameter(Mandatory)][string]$Output)
    if ($Output -notmatch '(?m)^Ssl_cipher\t[^\r\n\s]+\r?$') { throw 'No negotiated TLS cipher was observed. Verification failed.' }
}

function Assert-MySqlDeniedResult {
    param([Parameter(Mandatory)]$Result)
    if ($Result.ExitCode -eq 0 -or $Result.ErrorNumber -ne 1044) { throw 'Peer database isolation failed or could not be proved: expected MySQL error 1044 for USE of the peer database.' }
}

function Get-DatabaseAccountState {
    param($Definition, [hashtable]$AdminArguments)
    $user = ConvertTo-MySqlLiteral $Definition.username
    $hostValue = ConvertTo-MySqlLiteral $Definition.host
    $sql = (Get-DatabaseSqlPrefix) + "SELECT COUNT(*) FROM mysql.user WHERE User=$user AND Host=$hostValue;"
    $result = Invoke-MySqlQuery @AdminArguments -Sql $sql
    if ($result.Output -notin @('0', '1')) { throw 'Could not unambiguously determine existing account state.' }
    if ($result.Output -eq '0') { return $false }
    Assert-ExistingDatabaseAccount -Definition $Definition -AdminArguments $AdminArguments
    return $true
}

function Assert-ExistingDatabaseAccount {
    param($Definition, [hashtable]$AdminArguments)
    $account = Get-DatabaseAccountSql $Definition
    $grants = Invoke-MySqlQuery @AdminArguments -Sql ((Get-DatabaseSqlPrefix) + "SHOW GRANTS FOR $account;")
    Assert-DatabaseGrantRows $Definition @($grants.Output -split '\r?\n')
    $user = ConvertTo-MySqlLiteral $Definition.username
    $hostValue = ConvertTo-MySqlLiteral $Definition.host
    $ssl = Invoke-MySqlQuery @AdminArguments -Sql ((Get-DatabaseSqlPrefix) + "SELECT ssl_type FROM mysql.user WHERE User=$user AND Host=$hostValue;")
    if ($ssl.Output -notin @('ANY', 'X509', 'SPECIFIED')) { throw 'Existing user does not require TLS. Its settings are preserved; approve remediation separately.' }
}

function Invoke-ApprovedDatabaseBootstrap {
    param(
        [Parameter(Mandatory)]$Definitions,
        [Parameter(Mandatory)][hashtable]$ExistingUsers,
        [Parameter(Mandatory)][hashtable]$AdminArguments,
        [Parameter(Mandatory)][string]$Confirmation,
        [scriptblock]$ReadNewPassword = { param($Name) Read-Host "$Name : 새 전용 비밀번호 (password manager에 보관)" -AsSecureString }
    )
    $target = $AdminArguments.Target
    Assert-DatabaseDefinitions $Definitions $target.admin_username
    if ($Confirmation -cne "BOOTSTRAP $($target.mysql_db_system_ocid)") { throw 'Bootstrap was not approved. No DDL or grant was executed.' }
    foreach ($database in $Definitions.databases) {
        if (-not $ExistingUsers.ContainsKey($database.username)) { throw 'Missing reviewed existing-user state; no implicit account decision is permitted.' }
        $null = Invoke-MySqlQuery @AdminArguments -Sql (New-CreateDatabaseSql $database)
        if (-not $ExistingUsers[$database.username]) {
            $newPassword = & $ReadNewPassword $database.username
            try {
                $createSql = New-CreateDatabaseUserSql $database $newPassword
                $created = Invoke-MySqlQuery @AdminArguments -Sql $createSql
                $createSql = $null
                if ($created.Output -ne '0') { throw 'CREATE USER returned a warning (possibly an account created concurrently). No grants were added to this account. Review separately.' }
                $null = Invoke-MySqlQuery @AdminArguments -Sql (New-GrantDatabaseSql $database)
            } finally { $createSql = $null; if ($null -ne $newPassword) { $newPassword.Dispose() } }
        }
        Assert-ExistingDatabaseAccount $database $AdminArguments
        Write-Host "PASS: $($database.name) / $($database.username); own-schema DML grants and REQUIRE SSL verified."
    }
}

Export-ModuleMember -Function *
