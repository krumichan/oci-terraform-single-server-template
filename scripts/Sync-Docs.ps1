#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceDirectory,[switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$destination=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../docs'))
$source=[IO.Path]::GetFullPath($SourceDirectory)
if ($source -eq $destination) { throw '정본과 배포 사본 경로는 달라야 합니다.' }
# 오래된 3개 파일 정본으로 새 가이드를 부분 덮어쓰지 않는다.
$names=@('GETTING_STARTED.md','TOOLS_WINDOWS.md','ACCOUNT_SETUP.md','SSH_AND_DISCOVERY.md','REVIEW_AND_DEPLOY.md','CONNECT_AND_DATABASE.md','OPERATIONS.md','SOURCES.md','PROCEDURE_REFERENCE.md')
foreach ($name in $names) {
    $sourcePath=Join-Path $source $name
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "정본 누락: $sourcePath" }
}
if (-not $Check) { [void][IO.Directory]::CreateDirectory($destination) }
foreach ($name in $names) {
    $sourcePath=Join-Path $source $name;$targetPath=Join-Path $destination $name
    if ($Check) {
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or (Get-FileHash -LiteralPath $sourcePath).Hash -ne (Get-FileHash -LiteralPath $targetPath).Hash) { throw "배포 문서 정합성 실패: $name. 정본 검토 후 Sync-Docs.ps1을 실행하세요." }
        Write-Host "MATCH: $name"
    } else { Copy-Item -LiteralPath $sourcePath -Destination $targetPath;Write-Host "SYNC: $name (정본 → 배포 사본)" }
}
