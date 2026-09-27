Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Get-MySqlCertificateCommand {
    param([string]$Address,[int]$Port=3306)
    $ip=$null
    Assert-Condition ([Net.IPAddress]::TryParse($Address,[ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $ip.ToString() -ceq $Address) 'CERT_ENDPOINT_INVALID: canonical IPv4가 필요합니다.'
    $bytes=$ip.GetAddressBytes()
    Assert-Condition ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) 'CERT_ENDPOINT_PUBLIC: private MySQL 주소만 허용합니다.'
    Assert-Condition ($Port -eq 3306) 'CERT_PORT_INVALID: 기본 MySQL 3306만 허용합니다.'
    # Public certificate acquisition only; no username, password, SQL or trust-store
    # changes. OpenSSL does not authenticate the server here. Trust remains pending.
    # Strict SSH + independently checked host key protects the path to the VM.
    return "command -v timeout >/dev/null && command -v openssl >/dev/null || exit 126; timeout 20 openssl s_client -starttls mysql -connect ${Address}:$Port -showcerts < /dev/null"
}

function ConvertFrom-MySqlCertificateResult {
    param($Result)
    $diagnostic=Get-SafeNativeDiagnostic -Stderr $Result.Stderr -ExitCode $Result.ExitCode -Tool ssh -Operation certificate-read
    Assert-Condition ($diagnostic.code -ne 'TOOL_ARGUMENT') 'CERT_OPENSSL_UNSUPPORTED: VM openssl s_client의 -starttls mysql 지원을 확인하세요. 검증을 끄거나 다른 TLS 방식으로 자동 전환하지 않습니다.'
    return ConvertFrom-MySqlCertificateOutput $Result.Stdout
}

function Assert-MySqlCertificateTarget {
    param([hashtable]$Live,[hashtable]$Expected,[string]$Compartment)
    Assert-Condition ($Live.id -ceq $Expected.id -and $Live['compartment-id'] -ceq $Compartment -and $Live['shape-name'] -ceq 'MySQL.Free' -and $Live['lifecycle-state'] -ceq 'ACTIVE') 'CERT_TARGET_MISMATCH: DB 대상/compartment/MySQL.Free/ACTIVE를 확인하세요.'
    Assert-Condition ($Live.ContainsKey('endpoints') -and @($Live.endpoints | Where-Object { $_['ip-address'] -ceq $Expected.private_ip -and $_.port -eq $Expected.port }).Count -eq 1) 'CERT_ENDPOINT_MISMATCH: State 주소와 OCI DB endpoint가 다릅니다.'
    [void](Get-MySqlCertificateCommand $Expected.private_ip $Expected.port)
}

function ConvertFrom-MySqlCertificateOutput {
    param([string]$Text)
    Assert-Condition ($Text.Length -le 131072 -and $Text -notmatch 'PRIVATE KEY') 'CERT_OUTPUT_INVALID: 공개 인증서 응답만 허용합니다.'
    $certificates=[regex]::Matches($Text,'-----BEGIN CERTIFICATE-----\s*[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----')
    # The default OCI self-signed path must contain exactly one certificate.
    # A custom chain needs an independently supplied CA, not guessed trust roots.
    Assert-Condition ($certificates.Count -eq 1) 'CERT_CHAIN_REVIEW_REQUIRED: 인증서 1개를 확인하지 못했습니다. VM OpenSSL/DB endpoint 또는 별도 CA chain을 확인하세요.'
    $pem=$certificates[0].Value.Replace("`r",'').Trim()+"`n"
    try { $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($pem) }
    catch { throw 'CERT_PEM_INVALID: X.509 공개 인증서를 해석할 수 없습니다. 원문은 출력하지 않습니다.' }
    try {
        $san=@($certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) -replace '[\x00-\x1f\x7f]',' ' })
        return @{pem=$pem;certificate_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($certificate.RawData));subject=($certificate.Subject -replace '[\x00-\x1f\x7f]',' ');issuer=($certificate.Issuer -replace '[\x00-\x1f\x7f]',' ');san=$san;not_before=$certificate.NotBefore.ToUniversalTime().ToString('o');not_after=$certificate.NotAfter.ToUniversalTime().ToString('o');currently_valid=($certificate.NotBefore -le (Get-Date) -and $certificate.NotAfter -gt (Get-Date));subject_equals_issuer=($certificate.Subject -ceq $certificate.Issuer);trust='CANDIDATE_REQUIRES_INDEPENDENT_REVIEW';database_authentication='NOT_RUN'}
    } finally { $certificate.Dispose() }
}

function Save-MySqlCertificateCandidate {
    param([hashtable]$Certificate,[string]$Path,[hashtable]$Provenance)
    $full=[IO.Path]::GetFullPath($Path)
    Assert-Condition (Test-Path -LiteralPath (Split-Path $full -Parent) -PathType Container) 'CERT_DIRECTORY_MISSING: 저장 폴더를 먼저 준비하세요.'
    Assert-Condition (-not (Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath ($full+'.json'))) 'CERT_FILE_EXISTS: 기존 인증서/근거를 덮어쓰지 않습니다. 다른 OutputPath를 선택하세요.'
    # CreateNew prevents overwriting an existing pin, even with a concurrent writer.
    $stream=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Certificate.pem);$stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    $report=@{checked_at=[datetimeoffset]::UtcNow.ToString('o');source=$Provenance;file=$full;file_sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash}
    foreach ($key in $Certificate.Keys) { if ($key -ne 'pem') { $report[$key]=$Certificate[$key] } }
    $metadata=[Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 30))
    $metadataStream=[IO.File]::Open(($full+'.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $metadataStream.Write($metadata,0,$metadata.Length) } finally { $metadataStream.Dispose() }
    return $report
}

Export-ModuleMember -Function Get-MySqlCertificateCommand,Assert-MySqlCertificateTarget,ConvertFrom-MySqlCertificateOutput,ConvertFrom-MySqlCertificateResult,Save-MySqlCertificateCandidate
