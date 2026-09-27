#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z][a-z0-9-]{0,31}$')][string]$Environment = 'dev',
    [string]$TargetPath,
    [string]$DefinitionsPath,
    [Parameter(Mandatory)][string]$CaPath,
    [string]$MySqlPath = 'mysql',
    [ValidateSet('VERIFY_IDENTITY', 'VERIFY_CA')][string]$TlsMode = 'VERIFY_IDENTITY',
    [string]$ExpectedCaFileSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Database.psm1') -Force
$repoRoot = Split-Path $PSScriptRoot -Parent
$localDirectory = Join-Path $repoRoot ".local/$Environment"
if (-not $TargetPath) { $TargetPath = Join-Path $localDirectory 'connection.json' }
if (-not $DefinitionsPath) { $DefinitionsPath = Join-Path $localDirectory 'databases.json' }
$inputs = Read-DatabaseInputs $TargetPath $DefinitionsPath $Environment $CaPath $TlsMode $ExpectedCaFileSha256
$target = $inputs.Target
Write-Host "읽기 전용 DB 확인: $($target.tenancy_ocid) / $($target.region) / $($target.mysql_db_system_ocid)"
Write-Host "TLS endpoint: $($target.mysql_hostname):$($target.mysql_port) ($TlsMode)"
Confirm-DatabaseCertificateTrust $TlsMode $inputs.CaFileSha256
foreach ($database in $inputs.Definitions.databases) {
    $password = Read-Host "$($database.username)의 앱 전용 비밀번호" -AsSecureString
    try {
        $queryArguments = @{ Target = $target; Username = $database.username; Password = $password; CaPath = $inputs.CaPath; LocalDirectory = $localDirectory; MySqlPath = $MySqlPath; TlsMode = $TlsMode }
        $ownSql = (Get-DatabaseSqlPrefix) + ('USE `{0}`; SELECT DATABASE(); SELECT CURRENT_USER(); SHOW SESSION STATUS LIKE ''Ssl_cipher''; SELECT @@GLOBAL.partial_revokes; SELECT 1;' -f $database.name)
        $own = Invoke-MySqlQuery @queryArguments -Sql $ownSql
        $lines = @($own.Output -split '\r?\n')
        if ($lines.Count -ne 5 -or $lines[0] -cne $database.name -or $lines[1] -cne "$($database.username)@$($database.host)" -or $lines[3] -ne '1' -or $lines[4] -ne '1') { throw 'Own database/account identity or partial_revokes verification failed.' }
        Assert-MySqlTlsResult $own.Output
        $grants = Invoke-MySqlQuery @queryArguments -Sql 'SHOW GRANTS;'
        Assert-DatabaseGrantRows $database @($grants.Output -split '\r?\n')
        Write-Host "PASS: $($database.username) → $($database.name), verified TLS ($TlsMode)/cipher, exact DML grants."
        foreach ($peer in $inputs.Definitions.databases) {
            if ($peer.name -eq $database.name) { continue }
            $denied = Invoke-MySqlQuery @queryArguments -Sql ((Get-DatabaseSqlPrefix) + ('USE `{0}`;' -f $peer.name)) -AllowFailure
            Assert-MySqlDeniedResult $denied
            Write-Host "PASS: $($database.username) → $($peer.name) denied (MySQL 1044)."
        }
    } finally { $password.Dispose() }
}
if (@($inputs.Definitions.databases).Count -eq 1) { Write-Host 'Peer DB isolation: NOT RUN (only one configured database). Exact own-schema grants were verified.' }
Write-Host '실제 읽기 전용 검증 완료. 데이터 쓰기/DDL/드라이버/ORM migration 호환성과 애플리케이션 부하는 별도 검증 대상입니다.'
