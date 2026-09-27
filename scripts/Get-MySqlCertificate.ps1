#requires -Version 7.2
[CmdletBinding()]
param([string]$Environment='dev',[string]$ServerKey='server-1',[Parameter(Mandatory)][string]$SshPrivateKeyPath,[string]$KnownHostsPath=(Join-Path $HOME '.ssh/known_hosts'),[string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Ssh.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'lib/Certificate.psm1') -Force -DisableNameChecking
$context=Get-TaskContext $Environment
$settings=Read-JsonFile $context.Config
$identity=Get-ProfileIdentity $settings.oci_profile
if (-not $OutputPath) { $OutputPath=Join-Path $context.Directory 'mysql-server.pem' }
Assert-Condition (-not (Test-Path -LiteralPath $OutputPath) -and -not (Test-Path -LiteralPath ($OutputPath+'.json'))) 'CERT_FILE_EXISTS: 기존 인증서/근거는 보존합니다. 별도 OutputPath가 필요합니다.'
Set-TerraformContext $context
$result=Invoke-NativeTool -FilePath terraform -Arguments @('output','-json') -WorkingDirectory $context.Root -TimeoutSeconds 120 -Operation terraform-output
try { $outputs=$result.Stdout | ConvertFrom-Json -AsHashtable -Depth 100 } catch { throw 'CERT_STATE_JSON_INVALID: Terraform 출력 형식을 확인하세요. 원문은 출력하지 않습니다.' }
$deployment=$outputs.deployment.value
Assert-Condition ($deployment.tenancy_ocid -ceq $identity.Tenancy -and $deployment.region -ceq $settings.region -and $deployment.compartment_ocid -ceq $settings.compartment_ocid) 'CERT_DEPLOYMENT_MISMATCH: State와 현재 계정/리전/compartment가 다릅니다.'
Assert-Condition ($outputs.ContainsKey('mysql') -and $null -ne $outputs.mysql.value -and $outputs.servers.value.ContainsKey($ServerKey)) 'CERT_RESOURCE_MISSING: 배포된 MySQL과 선택한 VM이 필요합니다.'
$db=$outputs.mysql.value; $server=$outputs.servers.value[$ServerKey]
$live=Invoke-OciJson -Identity $identity -Region $settings.region -Arguments @('mysql','db-system','get','--db-system-id',$db.id)
Assert-MySqlCertificateTarget $live $db $settings.compartment_ocid
$vm=Invoke-OciJson -Identity $identity -Region $settings.region -Arguments @('compute','instance','get','--instance-id',$server.id)
Assert-Condition ($vm.id -ceq $server.id -and $vm['compartment-id'] -ceq $settings.compartment_ocid -and $vm.shape -ceq 'VM.Standard.E2.1.Micro' -and $vm['lifecycle-state'] -ceq 'RUNNING') 'CERT_VM_MISMATCH: 경유 VM의 대상/shape/RUNNING 확인에 실패했습니다.'
$ready=Test-SshReadiness -SshPrivateKeyPath $SshPrivateKeyPath -ExpectedPublicKeyPath $settings.ssh_public_key_path -Address $server.public_ip -KnownHostsPath $KnownHostsPath
$tools=Get-WindowsSshToolchain
$command=Get-MySqlCertificateCommand $db.private_ip $db.port
$arguments=Get-SshStrictArguments $tools $ready.public_key_path $KnownHostsPath $server.public_ip $command
# s_client can exit 1 after the unauthenticated TLS peer closes. Still require a
# well-formed certificate. 124 (timeout) / 255 (SSH) are failures, never accepted.
$result=Invoke-NativeTool -FilePath $tools.Ssh -Arguments $arguments -AcceptedExitCodes @(0,1) -TimeoutSeconds 40 -Operation certificate-read
$certificate=ConvertFrom-MySqlCertificateResult $result
$provenance=@{tenancy_ocid=$identity.Tenancy;region=$settings.region;compartment_ocid=$settings.compartment_ocid;mysql_id=$db.id;mysql_private_ip=$db.private_ip;mysql_port=$db.port;vm_id=$server.id;vm_public_ip=$server.public_ip;ssh_key_fingerprint=$ready.fingerprint;known_hosts_sha256=(Get-FileHash -LiteralPath $KnownHostsPath -Algorithm SHA256).Hash;method='Strict SSH to independently checked VM; unauthenticated MySQL TLS public certificate acquisition; no password or SQL'}
$report=Save-MySqlCertificateCandidate $certificate $OutputPath $provenance
Write-Host "후보 PEM: $($report.file)"
Write-Host "Subject: $($report.subject); Issuer: $($report.issuer); SAN: $($report.san -join ', ')"
Write-Host "기간: $($report.not_before) ~ $($report.not_after); currently_valid=$($report.currently_valid)"
Write-Host "DER certificate SHA256: $($report.certificate_sha256)"
Write-Host "PEM FILE SHA256 (ExpectedCaFileSha256): $($report.file_sha256)"
Write-Host 'CANDIDATE_REQUIRES_INDEPENDENT_REVIEW: 콘솔의 DB/VM/endpoint와 독립 확인한 SSH host key를 대조하세요. self-signed 후보의 수집은 신뢰 승인이 아닙니다. 가이드에서 신뢰 경로를 검토한 뒤 명시적인 pin을 사용하세요. DB 로그인/SQL/설정 변경은 실행하지 않았습니다.'
