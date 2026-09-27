#requires -Version 7.2
[CmdletBinding()]
param([string]$ScratchRoot=(Join-Path $PSScriptRoot '../.local/validation/certificate-tests'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../scripts/lib/Certificate.psm1') -Force -DisableNameChecking
$script:passed=0
function Check([bool]$Value,[string]$Message='Assertion failed') { if (-not $Value) { throw $Message } }
function Case([string]$Name,[scriptblock]$Body) { & $Body;$script:passed++;Write-Host "PASS [offline actual/unit]: $Name" }
function Fails([scriptblock]$Body,[string]$Pattern) { $caught=$null;try { & $Body | Out-Null } catch { $caught=$_ };Check ($null -ne $caught -and $caught.Exception.Message -match $Pattern) "Expected $Pattern" }
$scratch=Join-Path $ScratchRoot ([guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($scratch)
$rsa=[Security.Cryptography.RSA]::Create(2048)
try {
    $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=offline.example',$rsa,[Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert=$request.CreateSelfSigned([datetimeoffset]::UtcNow.AddMinutes(-5),[datetimeoffset]::UtcNow.AddDays(1))
    try { $pem=$cert.ExportCertificatePem() } finally { $cert.Dispose() }
} finally { $rsa.Dispose() }
Case 'read command has fixed protocol no credentials and bounded timeout' {
    $command=Get-MySqlCertificateCommand '10.0.2.10' 3306
    Check ($command -match 'timeout 20 openssl s_client -starttls mysql' -and $command -notmatch '(?i)password|SELECT|CREATE|ssl-mode')
}
foreach ($bad in @('10.0.2.10;id','127.0.0.1','203.0.113.10','example.com','10.1','::1')) { Case "reject endpoint $bad" { Fails { Get-MySqlCertificateCommand $bad 3306 } 'CERT_ENDPOINT' } }
Case 'reject alternate DB port' { Fails { Get-MySqlCertificateCommand '10.0.2.10' 33060 } 'CERT_PORT' }
$expected=@{id='ocid1.mysqldbsystem.oc1.test.offline';private_ip='10.0.2.10';port=3306}
$live=@{id=$expected.id;'compartment-id'='ocid1.compartment.oc1..offline';'shape-name'='MySQL.Free';'lifecycle-state'='ACTIVE';endpoints=@(@{'ip-address'='10.0.2.10';port=3306})}
Case 'matching OCI fixture and State target accepted MOCK' { Assert-MySqlCertificateTarget $live $expected 'ocid1.compartment.oc1..offline' }
Case 'different endpoint rejected MOCK' { $bad=$live.Clone();$bad.endpoints=@(@{'ip-address'='10.0.2.11';port=3306});Fails { Assert-MySqlCertificateTarget $bad $expected 'ocid1.compartment.oc1..offline' } 'CERT_ENDPOINT_MISMATCH' }
Case 'different compartment rejected MOCK' { Fails { Assert-MySqlCertificateTarget $live $expected 'ocid1.compartment.oc1..different' } 'CERT_TARGET_MISMATCH' }
Case 'unsupported MySQL STARTTLS gives actionable safe failure MOCK' {
    Fails { ConvertFrom-MySqlCertificateResult ([pscustomobject]@{Stdout='';Stderr='Value must be one of: smtp pop3 SECRET_SENTINEL';ExitCode=1}) } 'CERT_OPENSSL_UNSUPPORTED'
}
Case 'no certificate fails closed' { Fails { ConvertFrom-MySqlCertificateOutput 'SECRET_SENTINEL handshake failed' } 'CERT_CHAIN_REVIEW_REQUIRED' }
Case 'multiple certificates require independent CA review' { Fails { ConvertFrom-MySqlCertificateOutput ($pem+"`n"+$pem) } 'CERT_CHAIN_REVIEW_REQUIRED' }
Case 'private key material rejected' { Fails { ConvertFrom-MySqlCertificateOutput ($pem+"`n-----BEGIN PRIVATE KEY-----") } 'CERT_OUTPUT_INVALID' }
Case 'real generated X509 metadata stays untrusted without DB login' {
    $script:certificate=ConvertFrom-MySqlCertificateOutput ("untrusted stdout prelude SECRET_SENTINEL`n"+$pem)
    Check ($script:certificate.currently_valid -and $script:certificate.subject -eq 'CN=offline.example' -and $script:certificate.certificate_sha256 -match '^[A-F0-9]{64}$')
    Check ($script:certificate.trust -eq 'CANDIDATE_REQUIRES_INDEPENDENT_REVIEW' -and $script:certificate.database_authentication -eq 'NOT_RUN')
    Check (($script:certificate | ConvertTo-Json) -notmatch 'SECRET_SENTINEL')
}
Case 'real candidate file hash and metadata write' {
    $path=Join-Path $scratch 'candidate.pem'
    $script:report=Save-MySqlCertificateCandidate $script:certificate $path @{method='offline-generated-fixture'}
    Check ($script:report.file_sha256 -eq (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -and (Test-Path -LiteralPath ($path+'.json')))
    Check ($script:report.file_sha256 -ne $script:report.certificate_sha256) 'file and DER hashes must not be conflated'
}
Case 'existing pinned file preserved byte for byte' {
    Fails { Save-MySqlCertificateCandidate $script:certificate $script:report.file @{} } 'CERT_FILE_EXISTS'
    Check ((Get-FileHash -LiteralPath $script:report.file -Algorithm SHA256).Hash -eq $script:report.file_sha256)
}
Case 'concurrent metadata preserved without overwriting existing evidence MOCK' {
    $module=Get-Module Certificate
    & $module { function script:Get-FileHash { param([string]$LiteralPath,[string]$Algorithm);[IO.File]::WriteAllText($LiteralPath+'.json','CONCURRENT_EVIDENCE');Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm } }
    $path=Join-Path $scratch 'concurrent.pem';$caught=$null
    try { Save-MySqlCertificateCandidate $script:certificate $path @{} | Out-Null } catch { $caught=$_ }
    Check ($null -ne $caught -and [IO.File]::ReadAllText($path+'.json') -eq 'CONCURRENT_EVIDENCE')
    Import-Module (Join-Path $PSScriptRoot '../scripts/lib/Certificate.psm1') -Force -DisableNameChecking
}
Write-Host "CERTIFICATE TESTS: $script:passed PASS. X509/filesystem actual; API responses mocked; VM/OpenSSL/MySQL TLS live NOT_RUN. Evidence: $scratch"
