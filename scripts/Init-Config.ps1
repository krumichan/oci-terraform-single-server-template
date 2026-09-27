#requires -Version 7.2
[CmdletBinding()]
param([string]$Environment='dev')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
$context=Get-TaskContext $Environment
Protect-EnvironmentDirectory $context.Directory
foreach ($name in @('config','console-review','databases')) {
    $destination=Join-Path $context.Directory "$name.json"
    if (Test-Path -LiteralPath $destination) { Write-Host "보존: $destination"; continue }
    Copy-Item -LiteralPath (Join-Path $context.Root "examples/$name.json.example") -Destination $destination
    Write-Host "생성: $destination"
}
Write-Host 'docs/ACCOUNT_SETUP.md를 따라 값을 하나씩 준비하세요. 개인키/비밀번호는 JSON에 넣지 않습니다.'
Write-Host "입력 상태: pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment $Environment -Step Status"
