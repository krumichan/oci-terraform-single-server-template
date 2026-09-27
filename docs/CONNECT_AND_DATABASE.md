# 5. 서버 확인 → SSH 접속 → DB 연결

[무료·IAM 확인과 배포](REVIEW_AND_DEPLOY.md) → **접속 검증** → [운영·복구 매뉴얼](OPERATIONS.md)

**시작 조건:** 승인한 Apply가 완료되어 있습니다. 기본 구성은 서버 2대와 private MySQL 1개입니다.
지금부터는 계정의 실제 자원과 접속을 검증합니다. 명령 하나가 실패하면 다음으로 넘어가지 않습니다.
별도 표시가 없으면 **저장소 폴더의 일반 사용자 PowerShell 7**에서 실행합니다.

## 5-1. 생성된 자원의 ID와 IP 확인

```powershell
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev
```

아직 SSH 옵션을 넣지 않았으므로 이 결과만으로 서버 로그인이 확인된 것은 아닙니다.
화면에 나온 **server-1/server-2의 OCID와 공인 IP, MySQL OCID와 private IP**를 OCI 콘솔의 같은 자원과 대조합니다.

**완료 확인:** VM은 RUNNING/AMD Micro, MySQL은 ACTIVE/MySQL.Free로 조회됩니다.
`.local/dev/verification.json`과 `.local/dev/connection.json`이 생성됩니다.
기존 connection이 있으면 원본 대신 `connection.observed.json`을 만들므로 차이를 확인하고 임의 덮어쓰지 않습니다.
Autonomous를 켠 경우 DB별 조회도 확인되지만 wallet/SQL 접속은 별도 미검증입니다.

## 5-2. 두 서버의 host fingerprint 확인

**server-1과 server-2 두 서버 각각** 아래 확인이 필요합니다.

1. OCI **Compute → Instances → 해당 서버 이름**을 엽니다.
2. OCID와 공인 IP가 5-1 출력과 같은지 확인합니다.
3. 그 서버의 **Console history/boot 기록** 또는 **Console connections**를 통해 독립적으로 인증된 콘솔을 엽니다.
4. 기록에 나온 SSH host fingerprint를 확인합니다. 독립 콘솔에 로그인할 수 있는 경우 아래 Linux 명령으로 확인합니다.

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

이것은 Windows나 로컬 SSH 키 fingerprint가 아니라 **해당 VM 자체의 host key**입니다.
독립적인 확인 경로를 마련하지 못하면 여기서 멈춥니다.
`ssh-keyscan` 결과만으로 믿거나 확인을 끄는 방식은 사용하지 않습니다.

**완료 확인:** 서버 1과 서버 2 각각의 신뢰할 fingerprint를 알고 있습니다.
기존 키 경고가 있으면 IP 재사용·서버 교체 여부를 OCI OCID로 먼저 확인합니다.

## 5-3. 두 서버의 공인 IP를 한 번씩 입력

Windows PowerShell에서 아래 블록을 실행합니다. 실제 구성된 서버만 순서대로 물어봅니다.
앞에서 콘솔과 대조한 각 IP를 입력합니다.

```powershell
$settings = Get-Content -Raw .\.local\dev\config.json | ConvertFrom-Json -AsHashtable
$serversToTrust = @(foreach ($key in @($settings.servers.Keys | Sort-Object)) {
    $ip = Read-Host "$key 의 콘솔과 대조한 공인 IPv4"
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw 'IPv4 형식을 확인하세요.' }
    @{ key=$key; public_ip=$ip }
})
```

**완료 확인:** 두 대 구성이라면 두 번 질문합니다. 같은 창에서 다음 블록을 실행합니다.

## 5-4. host key를 비교하고 SSH 접속 확인

아래 명령에서 서버마다 처음 보는 host key 질문이 나옵니다.
**5-2의 해당 서버 fingerprint와 정확히 일치할 때만** `yes`를 입력합니다. 자동 yes가 아닙니다.

```powershell
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
$knownHosts = (Join-Path $HOME '.ssh\known_hosts').Replace('\','/')
$sshFirstArgs = @(
    '-F','none','-o','IdentityAgent=//./pipe/openssh-ssh-agent',
    '-o','IdentitiesOnly=yes','-o','GlobalKnownHostsFile=none',
    '-o',('UserKnownHostsFile="'+$knownHosts+'"'),
    '-o','StrictHostKeyChecking=ask','-o','UpdateHostKeys=no',
    '-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no',
    '-o','PreferredAuthentications=publickey','-o','ConnectTimeout=15',
    '-i',"$sshKey.pub"
)
foreach ($server in $serversToTrust) {
    Write-Host "확인 대상: $($server.key), $($server.public_ip)"
    & "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshFirstArgs "ubuntu@$($server.public_ip)" true
    if ($LASTEXITCODE -ne 0) { throw "SSH 확인 실패: $($server.key)" }
    pwsh -NoProfile -File .\scripts\Test-SshReady.ps1 -SshPrivateKeyPath $sshKey -Address $server.public_ip -KnownHostsPath $knownHosts
    if ($LASTEXITCODE -ne 0) { throw "SSH 사전 검사 실패: $($server.key)" }
}
```

**완료 확인:** 구성된 모든 서버의 접속 검사가 성공합니다.
서버 1만 등록하면 서버 2에서 검사가 실패하는 것이 정상입니다.
암호 입력 없이 실패하면 [3-3~3-4 agent 준비](SSH_AND_DISCOVERY.md)로 돌아갑니다. 키 암호를 제거하지 않습니다.

## 5-5. Ubuntu·Docker·노출 포트 검증

```powershell
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev -SshPrivateKeyPath (Join-Path $HOME '.ssh\translacat_oci') -CheckExternalPorts
```

**완료 확인:** cloud-init 완료, Docker active, SSH 및 외부 포트 검사가 통과합니다.
출력된 방화벽/리스너 규칙은 검토해야 합니다. `REVIEW_OUTPUT`이나 `NOT_RUN`을 PASS라고 읽지 않습니다.
한 접속원에서 3306/6379/8080/8000이 안 열리는 관찰만으로 모든 노출 가능성이 배제되는 것도 아닙니다.
실제 NSG·OS·Docker publish 규칙까지 함께 확인합니다.

<a id="mysql-client"></a>
## 5-6. 이제 MySQL 클라이언트 준비

로컬 **MySQL 서버를 설치/시작할 필요는 없습니다.** 필요한 것은 Oracle `mysql.exe` 클라이언트입니다.
Docker의 MySQL 서버는 그대로 둡니다. 현재 DB 스크립트가 Docker 클라이언트를 자동 사용하는 것은 아닙니다.

1. [MySQL Community Server 다운로드](https://dev.mysql.com/downloads/mysql/)에서 **8.4 LTS → Microsoft Windows → ZIP Archive (64-bit)**를 선택합니다.
2. 계정 로그인 없이 다운로드하는 링크가 보이면 **No thanks, just start my download**를 선택합니다.
3. 공식 다운로드의 무결성 검증 안내를 확인하고 ZIP을 본인 `Tools` 폴더의 새 하위 폴더에 풉니다.
4. 그 안의 `bin`에서 **mysql.exe**를 찾습니다. DLL 등 배포 파일을 함께 보존합니다.
5. 서버 초기화/configurator/Windows 서비스 설치는 실행하지 않습니다. `mysqlsh.exe`는 다른 프로그램입니다.

실제 실행 파일 경로를 묻는 다음 명령에 탐색기의 경로를 붙여넣습니다. 따옴표는 붙이지 않습니다.

```powershell
$mysqlExe = Read-Host '압축을 푼 폴더 안 bin\mysql.exe의 전체 경로'
if (-not (Test-Path -LiteralPath $mysqlExe -PathType Leaf)) { throw 'mysql.exe 파일을 찾지 못했습니다.' }
& $mysqlExe --version
```

**완료 확인:** Oracle MySQL의 버전이 나옵니다. DLL/runtime 오류면 [MySQL Windows 요구 사항](https://dev.mysql.com/doc/refman/8.4/en/windows-installation.html)의
Visual C++ runtime을 준비하고 다시 확인합니다.

[도구 안내의 사용자 Path 추가 방법](TOOLS_WINDOWS.md#terraform)으로 이 **bin 폴더**를 등록하면 이후 `mysql` 명령을 쓸 수 있습니다.
등록하지 않는 경우 아래 Bootstrap/Verify 명령에 매번 `-MySqlPath $mysqlExe`를 붙여 같은 창에서 실행합니다.

## 5-7. DB 인증서 후보 수집

먼저 OCI DB OCID/private endpoint가 5-1과 같고, 사용할 **server-1의 host key를 확인했다는 것**을 다시 확인합니다.
다음 helper는 그 SSH 경로를 통해 인증서만 수집합니다. DB 로그인/SQL 변경은 하지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\Get-MySqlCertificate.ps1 -Environment dev -ServerKey server-1 -SshPrivateKeyPath (Join-Path $HOME '.ssh\translacat_oci')
```

**완료 확인:** `.local/dev/mysql-server.pem`과 수집 보고서 `.pem.json`이 생성됩니다.
이미 있으면 자동 덮어쓰지 않습니다. 원본을 검토하고 새 수집이 필요하면 별도 `-OutputPath`를 사용합니다.
VM의 OpenSSL 기능이 미지원이면 중단합니다. TLS 검증을 꺼서 해결하지 않습니다.

## 5-8. 인증서가 어떤 경우인지 확인

```powershell
notepad .\.local\dev\mysql-server.pem.json
Get-FileHash -LiteralPath .\.local\dev\mysql-server.pem -Algorithm SHA256
```

subject/issuer, SAN(hostname), 만료일, 수집 대상과 신뢰 경로를 확인합니다.
**파일을 받았고 hash를 계산했다는 것만으로 신뢰가 성립하지는 않습니다.**
위에서 확인한 OCI 대상과 SSH host key, VM→DB private 경로가 맞아야 합니다.
DER certificate fingerprint와 **PEM 파일 SHA256**은 다른 값입니다.

다음 둘 중 **실제 인증서에 해당하는 경로 하나만** 선택합니다. 오류가 났다고 다른 경로로 자동 전환하지 않습니다.

| 실제 상황 | 선택할 연결 검증 |
|---|---|
| 신뢰할 CA와 그 CA가 발급한 인증서, 실제 SAN hostname을 확보했다 | 기본 `VERIFY_IDENTITY`. CA/hostname 둘 다 검증 |
| 실제 self-signed SYSTEM 인증서이며 위의 OCI/SSH 수집 경로와 PEM을 검토·승인했다 | 명시적 pinned `VERIFY_CA`. 고정한 파일/검증한 경로에 의존하며 hostname 검증은 하지 않음 |

어느 쪽인지 확인하지 못하면 중단합니다. 체인이 여러 개면 helper의 `CERT_CHAIN_REVIEW_REQUIRED`를 해결하고
인증된 경로로 issuer CA/chain을 확보합니다. leaf 인증서가 CA를 대신한다고 가정하지 않습니다.

## 5-9. 별도 창에 SSH tunnel 열기

**새 일반 사용자 PowerShell 7 창**을 저장소 폴더에서 엽니다.
5-1과 OCI 콘솔에서 대조한 **VM 공인 IP 하나**와 **MySQL private IP 하나**를 입력합니다.

```powershell
$vmIp = Read-Host 'host key 확인을 마친 VM의 공인 IPv4'
$mysqlPrivateIp = Read-Host 'OCI DB 상세와 대조한 MySQL private IPv4'
if ($vmIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or $mysqlPrivateIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw '입력한 IPv4를 확인하세요.' }
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
$knownHosts = (Join-Path $HOME '.ssh\known_hosts').Replace('\','/')
$sshTunnelArgs = @(
    '-F','none','-o','IdentityAgent=//./pipe/openssh-ssh-agent',
    '-o','IdentitiesOnly=yes','-o','GlobalKnownHostsFile=none',
    '-o',('UserKnownHostsFile="'+$knownHosts+'"'),
    '-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UpdateHostKeys=no',
    '-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no',
    '-o','PreferredAuthentications=publickey','-o','ConnectTimeout=15',
    '-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=30',
    '-i',"$sshKey.pub",'-N','-L',"127.0.0.1:13306:${mysqlPrivateIp}:3306"
)
& "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshTunnelArgs "ubuntu@$vmIp"
```

**완료 확인:** 오류 없이 연결을 유지합니다. 화면이 멈춘 듯 보이는 것이 정상일 수 있습니다.
이 창을 닫지 말고 원래 창으로 돌아갑니다. Ctrl+C 또는 창 종료 시 tunnel도 끝납니다.
이 연결이 유지되는 것만으로 VM→DB의 실제 로그인/TLS가 검증된 것은 아닙니다.
로컬 포트는 인터넷이 아닌 `127.0.0.1`에만 바인딩합니다.

## 5-10. DB 연결 설정의 작업용 사본 만들기

**원래 창**에서:

```powershell
if (Test-Path -LiteralPath .\.local\dev\connection.tunnel.json) { throw '기존 작업용 설정을 보존하고 내용을 먼저 검토하세요.' }
Copy-Item -LiteralPath .\.local\dev\connection.json -Destination .\.local\dev\connection.tunnel.json
notepad .\.local\dev\connection.tunnel.json
```

`tenancy_ocid`, `region`, `mysql_db_system_ocid`, `admin_username`은 변경하지 않습니다.
아래에서 고른 TLS 방식에 맞춰 **mysql_hostname과 mysql_port 두 항목만** 바꿉니다.

### A. VERIFY_IDENTITY를 선택한 경우

`mysql_hostname`에는 실제 인증서 SAN의 DB hostname을 유지하고 `mysql_port`만 `13306`으로 변경합니다.
이 hostname이 이 PC에서는 tunnel의 `127.0.0.1`을 가리키도록 hosts 파일에 **해당 한 줄만** 추가해야 합니다.

관리자 권한 메모장에서 `%SystemRoot%\System32\drivers\etc\hosts`를 열고
`127.0.0.1 실제_SAN_hostname` 형식으로 추가합니다. 기존 내용은 지우지 않습니다.
인증서에 없는 이름을 만들어 쓰지 않습니다. 작업 후 본인이 추가한 매핑만 검토해 제거합니다.

관리자가 인증한 경로로 받은 issuer CA/chain PEM을 `.local/dev/mysql-ca.pem`에 보관합니다.
그 신뢰 경로에서 받은 SHA256과 파일 SHA256을 대조합니다. 후보 leaf `mysql-server.pem`을 무조건 대신 쓰지 않습니다.

### B. self-signed pinned VERIFY_CA를 선택한 경우

검토·승인한 self-signed 인증서 경로일 때만 `mysql_hostname`을 `127.0.0.1`, `mysql_port`를 `13306`으로 변경합니다.
앞에서 **신뢰 경로를 검토한 PEM 파일**의 SHA256을 따로 보관합니다.
뒤 명령의 `-ExpectedCaFileSha256`에 넣을 값이며, 인증서 교체 시에는 신뢰 검토부터 다시 합니다.

**완료 확인:** Ctrl+S로 저장했습니다. 대상 OCI ID는 원본과 같고 endpoint 두 항목만 작업 목적에 맞게 바뀌었습니다.

## 5-11. 논리 DB와 계정 이름 확인

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Databases
```

기본 `translacat_ll / translacat_ll_app`, `translacat_chat / translacat_chat_app`를 쓰면 Enter로 유지합니다.
기존 행의 이름만 확인/수정하며 host와 추가 속성을 보존합니다. DB/계정을 실제 생성하는 명령이 아닙니다.

값을 변경했다면 기존 무료/IAM 검토가 무효화됩니다. 이미 배포한 환경에서 인프라 설정을 바꾸려는 목적이 아니라면
변경 범위가 DB 정의 파일뿐인지 확인하고 이후 재plan 전에 관련 검토를 다시 수행합니다.

## 5-12. 별도 승인을 받은 DB bootstrap

아래 A 또는 B 중 **5-8에서 선택한 한 경로만** 사용합니다.
관리자 비밀번호는 보안 입력창에 넣습니다. 스크립트가 실제 TLS/기존 권한을 읽은 뒤 변경 계획을 보여줍니다.
확인한 DB OCID·DB명·계정·권한이 맞고 **별도 SQL 변경 승인**을 했을 때만 `BOOTSTRAP <실제 DB OCID>`를 입력합니다.

A. 신뢰한 CA/hostname의 기본 검증:

```powershell
pwsh -NoProfile -File .\scripts\Bootstrap-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-ca.pem
```

B. 명시적으로 승인한 self-signed pinned 검증:

```powershell
$trustedPemHash = Read-Host '신뢰 경로를 검토한 PEM 파일의 SHA256 (64자리)'
if ($trustedPemHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'SHA256 형식을 확인하세요.' }
pwsh -NoProfile -File .\scripts\Bootstrap-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-server.pem -TlsMode VERIFY_CA -ExpectedCaFileSha256 $trustedPemHash
```

MySQL client를 Path에 등록하지 않았다면 해당 명령에 `-MySqlPath $mysqlExe`를 추가합니다.
B의 `TRUST CERTIFICATE <hash>`와 `BOOTSTRAP <DB OCID>`는 서로 다른 승인입니다.
이름별 비밀번호도 보안 입력창에서 받고, JSON/명령 인자에 비밀번호를 저장하지 않습니다.

**완료 확인:** Bootstrap 완료 메시지. 앱 테이블/Flyway·EF migration은 만들지 않습니다.
중간 실패면 실제 생성된 DB/계정을 먼저 확인하며 자동 재시도/drop/revoke하지 않습니다.

## 5-13. 같은 TLS 경로로 계정 권한 확인

A를 선택했다면:

```powershell
pwsh -NoProfile -File .\scripts\Verify-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-ca.pem
```

B를 선택했다면 같은 검토 hash로:

```powershell
pwsh -NoProfile -File .\scripts\Verify-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-server.pem -TlsMode VERIFY_CA -ExpectedCaFileSha256 $trustedPemHash
```

**완료 확인:** 실제 TLS cipher와 버전, `partial_revokes=ON`, 서비스 계정의 자기 DB DML 권한 및
다른 서비스 DB 접근 거부를 확인합니다. runtime에 ALL/DDL을 줘서 테스트를 통과시키지 않습니다.
앱 migration에는 별도 승인된 계정과 권한이 필요합니다.

## 5-14. 두 번째 Plan과 종료

같은 현재 DB 관리자 암호와 설정을 사용합니다. 날짜가 바뀌거나 입력이 변경됐다면 검토와 Preflight부터 갱신합니다.

```powershell
pwsh -NoProfile -File .\scripts\Plan.ps1 -Environment dev
```

**완료 확인:** 동일 입력에서 불필요한 변경이 없습니다.
앱 운영, wallet/SQL 선택 옵션, 실제 청구, backup/복원까지 모두 검증됐다고 보고하지 않습니다.
사용한 tunnel 창은 Ctrl+C로 종료합니다.

이후 IP/키 변경, State 보관, backup/복구/삭제는 [OPERATIONS](OPERATIONS.md)의 별도 절차를 따릅니다.
특히 MySQL 최종 백업은 현재 구성에서 `SKIP_FINAL_BACKUP`입니다. 무료 1개 제한 때문에 복원이
새 DB 생성과 충돌할 수 있으므로 복원을 위해 기존 DB부터 지우지 않습니다. Destroy는 별도 승인입니다.
