#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SshPrivateKeyPath,[string]$Address,[string]$KnownHostsPath=(Join-Path $HOME '.ssh/known_hosts'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Ssh.psm1') -Force -DisableNameChecking
$result=Test-SshReadiness -SshPrivateKeyPath $SshPrivateKeyPath -Address $Address -KnownHostsPath $KnownHostsPath
$result | ConvertTo-Json -Depth 5
Write-Host '이 검사는 서비스/키 등록/known_hosts를 변경하지 않습니다. Address를 생략하면 서버 연결은 NOT_RUN입니다.'
