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
Write-Host 'DB bootstrap 대상 (Terraform 출력과 OCI 콘솔에서 다시 비교하세요):'
Write-Host "Environment: $Environment"
Write-Host "Tenancy:     $($target.tenancy_ocid)"
Write-Host "Region:      $($target.region)"
Write-Host "DB System:   $($target.mysql_db_system_ocid)"
Write-Host "TLS endpoint: $($target.mysql_hostname):$($target.mysql_port)"
Write-Host "TLS mode: $TlsMode"
Confirm-DatabaseCertificateTrust $TlsMode $inputs.CaFileSha256
Write-Host '먼저 읽기 전용으로 TLS, partial_revokes, 기존 DB와 계정 권한을 확인합니다.'
$adminPassword = Read-Host 'MySQL 관리자 비밀번호 (저장/출력하지 않음)' -AsSecureString
try {
    $adminArguments = @{ Target = $target; Username = $target.admin_username; Password = $adminPassword; CaPath = $inputs.CaPath; LocalDirectory = $localDirectory; MySqlPath = $MySqlPath; TlsMode = $TlsMode }
    $tls = Invoke-MySqlQuery @adminArguments -Sql "SHOW SESSION STATUS LIKE 'Ssl_cipher';"
    Assert-MySqlTlsResult $tls.Output
    $partial = Invoke-MySqlQuery @adminArguments -Sql 'SELECT @@GLOBAL.partial_revokes;'
    if ($partial.Output -ne '1') { throw 'partial_revokes must be ON for exact database grants. The script does not modify server configuration.' }
    $existing = @{}
    foreach ($database in $inputs.Definitions.databases) {
        $existing[$database.username] = Get-DatabaseAccountState $database $adminArguments
        $schema = Invoke-MySqlQuery @adminArguments -Sql ((Get-DatabaseSqlPrefix) + "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=$(ConvertTo-MySqlLiteral $database.name);")
        if ($schema.Output -notin @('0', '1')) { throw 'Could not determine existing database state.' }
        Write-Host ("Database: {0} ({1}); user: {2}@{3} ({4}); permissions: SELECT, INSERT, UPDATE, DELETE on this database only" -f $database.name, $(if ($schema.Output -eq '1') { 'existing; existing data preserved' } else { 'new' }), $database.username, $database.host, $(if ($existing[$database.username]) { 'existing; password/grants unchanged' } else { 'new; gains access to this database including any existing data' }))
    }
    Write-Host '승인 범위: 위 DB의 CREATE DATABASE IF NOT EXISTS, 없는 계정 생성과 자체 DB DML 권한 부여.'
    Write-Host '기존 계정/데이터/비밀번호 변경, 테이블 migration, 삭제는 수행하지 않습니다. DDL은 자동 commit되어 부분 완료될 수 있습니다.'
    $required = "BOOTSTRAP $($target.mysql_db_system_ocid)"
    $confirmation = Read-Host "실행하려면 정확히 입력하세요: $required"
    Invoke-ApprovedDatabaseBootstrap -Definitions $inputs.Definitions -ExistingUsers $existing -AdminArguments $adminArguments -Confirmation $confirmation
    Write-Host 'Bootstrap 완료. Verify-Database.ps1로 각 앱 계정 로그인, TLS와 다른 DB 접근 거부를 확인하세요. 애플리케이션 migration은 별도입니다.'
} finally { $adminPassword.Dispose() }
