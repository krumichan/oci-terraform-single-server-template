# 상세 절차 참고본 — 이전 12단계 보존

이 파일은 패치 전 안내를 참고용으로 보존한 것입니다. **새 사용자는 [GETTING_STARTED](GETTING_STARTED.md)에서 시작하세요.**
설치 버전·진행 순서는 새 안내가 우선합니다. 아래는 기존 보안/복구 세부를 대조하기 위한 내용입니다.

---

# Oracle Cloud 계정에서 시작하는 Windows 12단계

이 문서는 저장소 `docs/`에 배포되는 실행 가이드입니다. 정본과 배포 사본은 유지보수자가 `Sync-Docs.ps1`로 동기화합니다. [README](../README.md), [운영·복구 상세](OPERATIONS.md), [공식 근거](SOURCES.md)를 함께 제공합니다. 모든 PowerShell 명령의 기본 실행 위치는 **이 저장소 루트**입니다. Windows 탐색기로 압축을 푼 폴더를 열고 주소창에 `pwsh`를 입력하세요. 특정 드라이브·작성자의 PC·형제 저장소가 필요하지 않습니다.

예시는 `dev`라는 환경 이름을 사용합니다. 실제 계정값을 임의로 만들거나 예시 IP/OCID를 그대로 적용하지 마세요. `REPLACE_...`, `YOUR_USER`, 문서 예시 IP `203.0.113.10`은 실제 사용할 값이 아닙니다. 파일명 대소문자와 JSON 경로를 그대로 사용하고 각 단계의 정상 결과를 확인한 후 다음으로 이동합니다. 기존 설정은 전체 예제로 덮어쓰지 않고 필요한 항목만 편집합니다.

| 만드는 것 | 먼저 준비하는 것 | 이 작업에서 만들지 않는 것 |
|---|---|---|
| AMD Micro 2대, 각 boot 50 GB, Ubuntu/Docker, VCN·subnet·NSG, private MySQL.Free 1개 | home region, 전용 compartment, API 인증/권한, SSH 키/agent, 관리 공인 IP | 앱 배포·앱 테이블·DNS·HTTPS 인증서·운영 데이터 이전 |
| 별도 승인 시 서비스별 DB/runtime 계정 | 신뢰 CA/인증서, DB별 비밀번호, 승인한 DB명/계정 | 자동 IAM 변경, 유료 fallback, ARM 전환, 기존 데이터 삭제 |
| 별도 ON 시 Always Free Autonomous 최대 2개 | 해당 계정 무료 자격·wallet·접속원 IP ACL | MySQL과 Oracle 엔진 자동 호환/이전 |

## 1. 도구 설치와 PATH 확인

- **지금 하는 일:** 기존 설치를 확인하고 필요한 명령만 준비합니다. 설치·시스템 설정은 사용자가 아래 내용을 검토한 뒤 직접 실행합니다.
- **실행 위치:** Windows PowerShell/브라우저. 설치 후 일반 사용자 **PowerShell 7**을 새로 엽니다.
- **클릭/명령:** 아래 공식 설치 표와 진단 명령을 순서대로 사용합니다.
- **얻는 값:** 실제 실행 파일 경로·버전·누락 도구·중복 PATH. OCI 계정값은 아직 필요 없습니다.
- **넣는 파일·JSON 경로:** 도구 설치 폴더를 Windows 사용자 `Path`에 추가합니다. 아직 JSON 변경은 없습니다.
- **안전한 예시:** `%USERPROFILE%\Tools\terraform` 같은 본인 선택 폴더를 사용하며 기존 `terraform.exe`를 덮어쓰지 않습니다.
- **정상 결과:** PowerShell ≥7.2, Terraform ≥1.9/<2, OCI CLI, Windows OpenSSH가 `PASS`; DB 단계 전에는 `mysql`도 `PASS`입니다.
- **실패하면 할 일:** 실행 경로를 먼저 확인합니다. 설치 후 기존 창에서는 PATH가 갱신되지 않으므로 새 창을 엽니다. 여러 버전은 임의 삭제하지 말고 사용할 버전의 경로를 선택합니다.

| 도구 | 공식 위치 → 클릭/명령 | 설치·검증 세부 |
|---|---|---|
| PowerShell 7 | [Microsoft 설치](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows) → WinGet 또는 MSI | Windows PowerShell에서 `winget install --id Microsoft.PowerShell --source winget` 또는 공식 MSI. 설치 후 `pwsh --version`. 5.1은 삭제하지 않습니다. |
| Terraform | [HashiCorp 설치](https://developer.hashicorp.com/terraform/install) → Windows AMD64 ZIP | PC 아키텍처에 맞는 CLI를 받습니다. 서버는 항상 AMD입니다. ZIP checksum과 서명 확인 안내를 따라 검증하고 본인 선택 폴더에 풉니다. Terraform `1.9.8`은 이전 검증 버전이며 현재 사용할 ≥1.9/<2 버전은 `Validate`로 다시 검증합니다. |
| OCI CLI | [Oracle Windows 설치](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) → Windows → 공식 release MSI | 정상 빈 목록 출력 계약을 검증한 `3.94.0`을 별도 설치 경로에 준비합니다. 이미 설치한 CLI는 보존하고 공식 manual/virtualenv 설치 안내를 사용합니다. `oci --version`과 `Test-Prerequisites.ps1`이 선택된 PATH의 버전을 확인합니다. |
| OpenSSH Client | [Microsoft OpenSSH](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse) → Windows 설정 → 선택적 기능 → 기능 보기 → OpenSSH Client | Client만 필요합니다. 관리자 설치 명령은 `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0`. SSH Server 설치/로컬 22번 inbound 개방은 필요하지 않습니다. |
| Oracle MySQL CLI | [Windows ZIP 설치](https://dev.mysql.com/doc/refman/8.4/en/windows-install-archive.html) → 공식 Windows ZIP 배포판 | ZIP의 `bin\mysql.exe`와 DLL을 같이 보존합니다. 로컬 MySQL 서버 초기화/서비스 시작 없이 client만 사용합니다. 필요한 Visual C++ runtime은 공식 설치 요구사항을 따릅니다. `mysql --version`에 Oracle MySQL을 확인합니다. `mysqlsh`(MySQL Shell)는 이 스크립트가 사용하는 `mysql.exe`와 다른 도구입니다. |

설치 폴더를 사용자 PATH에 추가하려면 시작 → “환경 변수 편집” → “사용자 환경 변수” → `Path` → 편집 → 새로 만들기에 **exe가 든 폴더**를 넣습니다. 전체 PATH를 지우거나 예시로 덮어쓰지 않습니다. `mysql.exe`를 PATH에 추가하지 않으면 DB 스크립트에 `-MySqlPath '실제\bin\mysql.exe'`를 명시할 수 있습니다.

```powershell
$PSVersionTable.PSVersion
Get-Command pwsh,terraform,oci,ssh,mysql -All -ErrorAction SilentlyContinue | Select-Object Name,Source
pwsh -NoProfile -File .\scripts\Test-Prerequisites.ps1
pwsh -NoProfile -File .\scripts\Init-Config.ps1 -Environment dev
```

`Test-Prerequisites`는 설치/PATH/서비스를 변경하지 않고 10초 제한의 버전 조회만 합니다. Terraform/OCI/MySQL은 선택된 PATH 경로, SSH는 Windows OpenSSH 경로를 표시합니다. OCI CLI의 정상 빈 목록은 고정 RC·`--all`·JSON 출력·정확한 3.94.0 버전에서만 판정합니다. 다른 버전이나 모호한 출력이면 사용량 0으로 추정하지 않고 멈춥니다. Git Bash SSH가 먼저 잡히면 혼용 안내를 읽으세요. PowerShell 실행 정책에 막히면 파일 출처·서명과 조직 정책을 확인합니다. 무조건 `Bypass`/`Unrestricted`로 실행하지 않습니다.

## 2. Home Region·계정 상태·기존 사용량 확인

- **지금 하는 일:** Trial 크레딧과 Always Free를 구분하고 기존 사용량까지 확인합니다.
- **실행 위치:** OCI 콘솔의 계정 메뉴, region 선택기, Billing & Cost Management, Compute/Storage/Databases.
- **클릭/명령:** 프로필 → Tenancy details에서 tenancy OCID; region 메뉴 → Manage regions에서 Home 표시. Billing → 계정/구독 상태에서 Trial/PAYG 등 표시를 기록합니다. 모든 compartment/구독 region에서 Compute Instances, Block Storage의 Boot/Block Volumes와 Backups, MySQL DB Systems/Backups, Autonomous를 확인합니다. API 재검사는 6~8단계입니다.
- **얻는 값:** tenancy OCID·정확한 home region code·계정 상태·기존/분리 volume 및 backup 목록.
- **넣는 파일·JSON 경로:** `.local/dev/config.json` → `region`; `.local/dev/console-review.json` → `tenancy_ocid`, `region`, `account_status`, `notes`. 확인 boolean은 7단계까지 미확인 상태를 유지합니다.
- **안전한 예시:** `region`은 콘솔의 실제 `ap-...-1` code이며 display name을 번역해 넣지 않습니다. `account_status`는 콘솔에서 읽은 문구입니다.
- **정상 결과:** 대상 home region 하나가 분명하고 기존 사용량을 열람할 수 있습니다. [Always Free 공식 문서](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)와 계정의 무료 표시가 일치합니다.
- **실패하면 할 일:** 읽을 수 없는 compartment/사용량 또는 정책 충돌이 있으면 멈추고 필요한 조회 권한/Oracle 지원을 확인합니다. Trial 잔액이나 현재 청구 0만으로 통과하지 않습니다. 새 계정이어도 사용량을 0으로 추정하지 않습니다.

현재 검사 상한은 기존 포함 AMD Micro 2대, Compute boot/block 200 GB, volume backups 5개, MySQL.Free 1개와 별도 backup 50 GB, Autonomous 최대 2개 각각 20 GB입니다. 실행일 [SOURCES](SOURCES.md)를 다시 읽습니다. 한도는 계정 전체 무료 자격이나 물리 재고를 보증하지 않습니다.

## 3. 전용 compartment 선택

- **지금 하는 일:** 배포·권한·State 대상이 명확한 compartment를 선택합니다.
- **실행 위치:** OCI 콘솔 → Identity & Security → Compartments.
- **클릭/명령:** 기존 전용 compartment를 먼저 확인합니다. 없으면 생성할 부모·이름·목적을 검토한 뒤 Create compartment를 사용합니다. 상세의 OCID → Copy를 누릅니다. 기존 앱 자원을 이동하지 않습니다.
- **얻는 값:** `ocid1.compartment.oc1..`로 시작하는 실제 compartment OCID와 부모 경로.
- **넣는 파일·JSON 경로:** `.local/dev/config.json` → `compartment_ocid`.
- **안전한 예시:** 이름 `translacat-free`는 표시 이름이고 JSON에는 그 OCID를 넣습니다. `ocid1.compartment.oc1..REPLACE_ME`는 유효한 값이 아닙니다.
- **정상 결과:** OCI 로그인 계정의 활성 전용 compartment가 선택됩니다. root tenancy OCID와 다릅니다.
- **실패하면 할 일:** root는 광범위 배포/권한 오입력을 막기 위해 이 템플릿에서 금지됩니다. `ocid1.tenancy...`를 넣지 않습니다. 생성 권한이 없으면 관리자에게 전용 compartment를 요청하고 기존 root 권한을 임의 확대하지 않습니다.

## 4. API 키 등록·profile·ACL·인증 확인

- **지금 하는 일:** OCI 요청 서명용 API 키를 준비합니다. VM SSH 키와 별개입니다.
- **실행 위치:** OCI 콘솔의 본인 사용자 상세 → API keys; Windows 일반 사용자 PowerShell.
- **클릭/명령:** 프로필 → My profile 또는 Identity & Security → Domains → 해당 Domain → Users → 본인 → API keys → Add API key. 기존 전용 키가 있으면 재사용 가능 여부를 확인합니다. 신규 Generate API key pair에서는 private key를 내려받아 저장소 밖 본인 `.oci` 폴더에 안전하게 저장한 뒤 Add. Configuration File Preview의 값을 복사합니다.
- **얻는 값:** `user`, `fingerprint`, `tenancy`, `region`, `key_file`. OCID/fingerprint는 식별자이고 개인키/암호는 비밀입니다.
- **넣는 파일·JSON 경로:** `%USERPROFILE%\.oci\config`의 `[TRANSLACAT]` section; `.local/dev/config.json` → `oci_profile="TRANSLACAT"`. 기존 `[DEFAULT]`/다른 profile은 보존합니다.
- **안전한 예시:** 아래 profile에서 `REPLACE`와 `YOUR_USER`를 실제 값으로 바꾸되 키 본문을 복사하지 않습니다. `key_file`은 내려받은 키의 실제 파일 경로입니다.
- **정상 결과:** 읽기 인증 명령이 home region 행을 반환하고 콘솔 home region과 일치합니다. 개인키 ACL은 본인만 읽도록 제한됩니다.
- **실패하면 할 일:** `NotAuthenticated`는 user/fingerprint/key_file·키 등록 여부·PC 시각을 확인합니다. `NotAuthorizedOrNotFound`는 읽기 권한과 대상 OCID를 확인합니다. 키 본문/암호를 로그·채팅에 올리지 않습니다.

```ini
[TRANSLACAT]
user=ocid1.user.oc1..REPLACE_ME
fingerprint=REPLACE_ME
tenancy=ocid1.tenancy.oc1..REPLACE_ME
region=REPLACE_WITH_HOME_REGION
key_file=C:/Users/YOUR_USER/.oci/oci_api_key.pem
```

아래는 **본인이 소유한 정확한 API 개인키 파일 하나**의 ACL을 제한합니다. 기존 파일 내용은 바꾸지 않습니다. 먼저 `$apiKey` 경로를 확인하고 공유 키/조직 관리 키에는 관리자 정책을 따릅니다.

```powershell
$apiKey = Join-Path $HOME '.oci\oci_api_key.pem'
Get-Item -LiteralPath $apiKey | Select-Object FullName,Length
$apiKeyAcl = Get-Acl -LiteralPath $apiKey
$apiKeyAcl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($apiKeyAcl.Access)) { [void]$apiKeyAcl.RemoveAccessRuleSpecific($rule) }
$apiKeySid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$apiKeyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($apiKeySid,'FullControl','Allow'))
Set-Acl -LiteralPath $apiKey -AclObject $apiKeyAcl
(Get-Acl -LiteralPath $apiKey).Access | Select-Object IdentityReference,FileSystemRights,IsInherited
notepad (Join-Path $HOME '.oci\config')
$tenancyId = 'REPLACE_WITH_TENANCY_OCID'
$homeRegion = 'REPLACE_WITH_HOME_REGION'
oci --profile TRANSLACAT --auth api_key --region $homeRegion iam region-subscription list --tenancy-id $tenancyId --all
if ($LASTEXITCODE -ne 0) { throw 'API 인증/조회 실패. 비밀 없는 오류 코드와 request ID를 확인하세요.' }
```

암호화 API 개인키는 SSH agent에 등록하는 키가 아닙니다. 이 실행 경로의 OCI CLI·provider가 동일하게 사용할 보호된 인증 설정을 준비하고, 비대화형 서명을 확인해야 합니다. API 암호를 argv/스크립트/JSON에 넣거나 암호를 제거하는 우회는 하지 않습니다. 키 교체·API 등록 역시 계정 인증 변경이므로 사용자가 대상과 목적을 확인하고 수행합니다.

## 5. SSH 키·Windows agent·관리 공인 IP 준비

- **지금 하는 일:** passphrase가 있는 SSH 키를 만들거나 기존 전용 키를 선택하여 자동 Verify가 안전하게 인증할 수 있게 합니다.
- **실행 위치:** Windows. 서비스 설정만 관리자 PowerShell, 키 생성·등록은 **실제 작업할 일반 사용자** PowerShell입니다.
- **클릭/명령:** 아래 순서대로 실행합니다. 공인 IPv4는 OCI Compute 생성 화면의 SSH source “My IP address” 표시 또는 신뢰하는 네트워크 관리자에게 확인하며 화면에서 자원을 생성하지 않습니다. 현재 PC의 VPN/프록시 egress와 같아야 합니다.
- **얻는 값:** private key 경로, `.pub` 경로, agent에 등록된 fingerprint, 실제 공인 IPv4/32.
- **넣는 파일·JSON 경로:** `.local/dev/config.json` → `ssh_public_key_path`, `ssh_allowed_cidr`. 개인키/passphrase는 JSON에 넣지 않습니다.
- **안전한 예시:** `C:/Users/YOUR_USER/.ssh/translacat_oci.pub`; `203.0.113.10/32`는 설명 전용이며 실제 연결에 사용할 수 없습니다.
- **정상 결과:** `ssh-add -l -E sha256`에 본인 `.pub` fingerprint가 있고 `Test-SshReady` 로컬 점검이 PASS입니다. 아직 서버 접속은 하지 않습니다.
- **실패하면 할 일:** agent 없음은 관리자 서비스 설정, key 없음은 일반 사용자 `ssh-add`, 혼용은 Windows 실행 경로를 확인합니다. 키 암호 제거/저장 또는 host 확인 해제로 우회하지 않습니다. `ipconfig`의 10/172.16~31/192.168 주소는 공인 IP가 아닙니다.

일반 사용자 창에서 신규 키를 생성합니다. 파일이 이미 있으면 재생성하지 않고 해당 공개키를 확인합니다. passphrase 입력은 화면 프롬프트에서만 합니다.

```powershell
$sshTools = Join-Path $env:WINDIR 'System32\OpenSSH'
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
New-Item -ItemType Directory -Path (Split-Path $sshKey -Parent) -Force | Out-Null
if ((Test-Path -LiteralPath $sshKey) -or (Test-Path -LiteralPath "$sshKey.pub")) { Write-Host '기존 키 보존: 공개키와 소유권을 확인하세요.' }
else { & "$sshTools\ssh-keygen.exe" -t ed25519 -f $sshKey -C 'translacat-oci' }
& "$sshTools\ssh-keygen.exe" -lf "$sshKey.pub" -E sha256
```

**관리자 PowerShell에서 서비스 변경 내용을 확인한 뒤 한 번만:**

```powershell
Get-Service ssh-agent
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent
Get-Service ssh-agent
```

**관리자 창을 닫고 원래 일반 사용자 창에서:**

```powershell
& "$env:WINDIR\System32\OpenSSH\ssh-add.exe" $sshKey
& "$env:WINDIR\System32\OpenSSH\ssh-add.exe" -l -E sha256
pwsh -NoProfile -File .\scripts\Test-SshReady.ps1 -SshPrivateKeyPath $sshKey
```

Windows OpenSSH와 Git Bash의 ssh-agent는 서로 다를 수 있습니다. Verify는 Windows `System32\OpenSSH` 도구와 Windows agent를 사용합니다. Git socket이 들어간 `SSH_AUTH_SOCK`가 감지되면 Git Bash를 닫고 Windows PowerShell 새 세션에서 환경 출처를 확인합니다. 기존 Git 설정/서비스를 임의로 삭제하지 않습니다. OS 로그아웃·재부팅 후에는 agent와 키 등록을 다시 확인합니다.

## 6. 계정 discovery와 AD/image/limit 입력

- **지금 하는 일:** 실제 계정에서 후보와 전체 사용량을 읽고 고정할 값을 선택합니다.
- **실행 위치:** Windows 저장소 루트; OCI 콘솔 Compute 생성 화면의 Placement/Image, MySQL 생성 화면의 AD, Limits·Quotas.
- **클릭/명령:** 아래 discovery 명령 후 두 결과 파일을 엽니다. 콘솔에서 선택 항목을 대조하되 생성 버튼을 누르지 않습니다.
- **얻는 값:** 계정 prefix 포함 전체 AD 이름, Canonical Ubuntu 22.04/24.04 x86 image OCID/최소 boot 크기, 실제 limit 이름/scope/잔여량 후보.
- **넣는 파일·JSON 경로:** `.local/dev/config.json` → `servers.server-1.availability_domain`, `servers.server-1.image_ocid`, `servers.server-2.availability_domain`, `servers.server-2.image_ocid`, `mysql_availability_domain`, `limit_checks`. 후보 경로는 `discovery-suggestions.json`에 표시됩니다.
- **안전한 예시:** AD의 계정 prefix를 포함한 전체 문자열을 복사합니다. 이미지 OCID의 region 문자열을 편집하지 않습니다. `server-1`/`server-2` map key는 안정된 자원 식별자로 보존합니다.
- **정상 결과:** `DISCOVERED`와 실제 후보가 출력됩니다. 이것은 무료 PASS가 아닙니다. 제안 파일은 설정을 덮어쓰지 않습니다.
- **실패하면 할 일:** null/404/미지원/권한 거부를 0으로 바꾸지 않습니다. MySQL.Free 한도 의미가 불명확하면 멈추고 콘솔/공식 지원에서 확인합니다. shape가 있어도 host capacity는 별개입니다.

```powershell
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev -Discover
notepad .\.local\dev\discovery.json
notepad .\.local\dev\discovery-suggestions.json
notepad .\.local\dev\config.json
```

`limit_checks`는 [OPERATIONS의 입력 예시](OPERATIONS.md)를 사용하되 discovery의 실제 이름과 scope를 선택합니다. AD scope에는 전체 AD 이름을 넣고 REGION/GLOBAL에는 임의 AD를 붙이지 않습니다. 기존 자원을 다른 compartment로 옮겨 검사를 통과시키지 않습니다.

## 7. MySQL NSG IAM과 당일 콘솔 확인

- **지금 하는 일:** API 사용자 권한과 MySQL DB 자체의 NSG/VNIC 권한을 분리해 검토하고 무료 조건의 사람 확인을 기록합니다.
- **실행 위치:** OCI 콘솔 → Identity & Security → Domains/Groups 및 Policies, 대상 compartment의 부모부터 root tenancy 정책; Windows JSON 편집기.
- **클릭/명령:** `iam-review.json`의 정책 ID·hash·범위 후보를 콘솔의 실제 ACTIVE statement/그룹 membership과 대조합니다. [최소 권한 템플릿](../examples/mysql-nsg-policy.txt.example)을 읽고 그룹 OCID와 DB/NSG/subnet compartment를 치환합니다. 기존 권한이 충족하면 생성하지 않습니다. 없거나 다른 정책과 충돌하면 변경할 정책 위치·statement diff·그룹·대상 compartment를 먼저 제시하고 **별도 명시적 승인 후에만** 관리자 콘솔 → Policies → root tenancy scope → Create policy → Show manual editor에서 승인 범위만 입력합니다.
- **얻는 값:** 검토한 정책 OCID, 그룹 OCID, 대상 scope, 변경 필요 여부, 미확인 항목. 사람의 관리자 권한은 DB resource principal 권한을 대신하지 않습니다.
- **넣는 파일·JSON 경로:** `.local/dev/console-review.json` → 아래 모든 확인 항목 및 `mysql_nsg_iam`; 이전 버전 사용자 설정에는 해당 object만 예제에서 추가하며 기존 값/파일을 덮어쓰지 않습니다. 기본 템플릿은 [console-review 예제](../examples/console-review.json.example)입니다.
- **안전한 예시:** `policy_disposition="EXISTING_SUFFICIENT"`는 실제 기존 정책 검토 후에만, 신규 정책은 별도 승인·생성 확인 후 `CREATED_WITH_APPROVAL`입니다. `UNREVIEWED`/빈 정책 목록은 통과하지 않습니다.
- **정상 결과:** IAM의 상태는 `REVIEWED_PREREQUISITES`이며 `effective_authorization=NOT_PROVEN`으로 남습니다. 문자열 발견/정책 조회는 실제 유효 권한이나 DB 생성 성공 보증이 아닙니다.
- **실패하면 할 일:** 정책 조회 권한이 없거나 조건/상속/그룹이 불명확하면 REVIEW_REQUIRED로 중단합니다. NSG 제거, DB 공개, tenancy 전역 관리자 권한 부여로 우회하지 않습니다. 정책 변경 후 propagation을 기다렸다가 읽기 discovery/Preflight를 다시 실행합니다.

이 구성은 DB·NSG·subnet을 한 compartment에 만듭니다. 따라서 `mysql_nsg_iam.db_compartment_ocid`, `nsg_compartment_ocid`, `subnet_compartment_ocid` 세 값 모두 `config.json`의 `compartment_ocid`와 같아야 합니다. 그룹은 Domains → 해당 Domain → Groups → API 사용자가 포함된 그룹 → OCID에서 복사합니다. 정책을 root tenancy에 둬도 statement의 자원 범위는 해당 compartment ID로 제한합니다. `request.principal.type='mysqldbsystem'`인 DB resource principal의 NSG/VNIC 권한과 사용자 그룹의 네트워크 권한을 각각 검토합니다. [Oracle 필수 정책](https://docs.oracle.com/en-us/iaas/mysql-database/doc/mandatory-policies-permissions.html)

| JSON 경로 (`console-review.json`) | 직접 확인할 화면/근거 → 입력 |
|---|---|
| `reviewed_on`, `tenancy_ocid`, `region`, `account_status` | 실행일, 2단계 tenancy/home region/계정 상태. 날짜만 오늘로 바꾸지 않습니다. |
| `official_policy_confirmed` | [SOURCES](SOURCES.md)의 공식 URL을 실행일에 읽고 현재 무료 상한·조건 확인 후 true |
| `policy_conflicts_resolved` | 공식 문서 간 차이/계정과의 모순을 검토·해소 후 true. 미해소면 false |
| `tenancy_wide_inspect_confirmed` | 모든 구독 region·root/하위 compartment 자원을 조회할 권한/범위를 확인 후 true |
| `always_free_compute_confirmed` | Compute Create instance 화면에서 AMD Micro·선택 OS가 Always Free 대상인지 확인 후 true |
| `always_free_mysql_confirmed` | MySQL Create DB System 화면에서 MySQL.Free·home region·선택 AD 무료 표시 확인 후 true |
| `mysql_backup_policy_confirmed` | MySQL 무료 자동 backup 1일, soft delete/PITR 없음, 기존 잔여 backup/50 GB 근거 확인 후 true |
| `always_free_autonomous_confirmed` | Autonomous ON일 때만 해당 생성 화면의 Always Free·20 GB·mTLS/ACL 확인 후 true. OFF면 false 유지 가능 |
| `limits_quotas_reviewed` | Governance & Administration → Limits, Quotas and Usage: service/region/AD/compartment를 바꾸어 실제 quota/usage/available 확인 후 true |
| `notes` | 화면명·확인일·검토한 사항·미해소 이유 기록. 개인키/비밀번호는 금지 |
| `mysql_nsg_iam.reviewed_on`, `tenancy_ocid`, `region` | 같은 실행일·테넌시·home region |
| `mysql_nsg_iam.deployer_group_ocid`, `policy_ocids` | 실제 membership을 확인한 그룹과 검토한 ACTIVE 정책 ID 배열 |
| `mysql_nsg_iam.api_user_group_membership_confirmed`, `user_permissions_confirmed` | API 키의 user가 정책 그룹에 속하고 템플릿에 필요한 사용자 권한을 갖는지 직접 확인 후 true |
| `mysql_nsg_iam.db_principal_permissions_confirmed`, `conditions_and_scope_confirmed` | DB resource principal 권한 및 DB/NSG/subnet scope와 조건을 확인 후 true |
| `mysql_nsg_iam.conflicts_resolved`, `unresolved_items` | 미확인 조건이 모두 해소되었을 때 true와 빈 배열. 단순 삭제로 해결했다고 기록하지 않음 |
| `mysql_nsg_iam.separately_approved_change_confirmed` | 신규/수정 정책을 별도 승인받아 적용한 경우에만 true. 기존 충분 정책이면 false 유지 |

```powershell
notepad .\.local\dev\iam-review.json
notepad .\.local\dev\console-review.json
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev
```

## 8. 저장한 Plan과 무료 잔여량 검토

- **지금 하는 일:** 생성/변경 계획을 저장하고 무료 정책·대상·삭제/교체를 검토합니다. Plan은 인프라 변경을 적용하지 않습니다.
- **실행 위치:** Windows 저장소 루트와 OCI 콘솔의 기존 자원/무료 표시.
- **클릭/명령:** `Preflight` 성공 후 아래 `Plan`을 실행합니다. MySQL 관리자 암호는 secure prompt로 입력하고 암호 관리자에 보관합니다. 기존 환경 재plan에는 현재 암호를 사용합니다.
- **얻는 값:** 정확한 tenancy/region/compartment, 자원별 before/after, 기존+계획 사용량, saved plan SHA256와 승인 대상.
- **넣는 파일·JSON 경로:** `.local/dev/.plans/<timestamp>/deployment.tfplan`, 같은 폴더의 `summary.json`, `.local/dev/reviewed-plan.json`을 스크립트가 생성합니다. raw plan JSON은 파일로 보관하지 않습니다. 비밀이 포함될 수 있어 공유하지 않습니다. 사용자 입력 변경은 `.local/dev/config.json`에서만 하고 새 Preflight/Plan을 만듭니다.
- **안전한 예시:** 기본 새 환경은 AMD 2대·MySQL 1개와 네트워크를 생성하며 Autonomous는 0개입니다. paid shape/유료 image, HA/PITR/자동확장, 삭제/교체가 있으면 승인하지 않습니다.
- **정상 결과:** `PREFLIGHT PASS`, `LIVE_PLAN_VERIFIED_AWAITING_APPLY_APPROVAL`. 무료 잔여량이 기존 사용량과 일치하고 계획 범위에 동의할 수 있습니다.
- **실패하면 할 일:** stale plan/변경된 설정/교체 제안은 원인을 확인하고 새 계획을 만듭니다. State 삭제·기존 리소스 선삭제·유료/ARM 자동 대안은 사용하지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev
pwsh -NoProfile -File .\scripts\Plan.ps1 -Environment dev
```

## 9. 승인된 Apply와 VM/SSH 검증

- **지금 하는 일:** 검토한 plan만 적용하고 실제 자원·host key·비대화형 SSH·OS/Docker/방화벽을 확인합니다.
- **실행 위치:** Windows 저장소 루트; OCI Compute → Instances → 해당 OCID; 필요 시 Console connections/Console history.
- **클릭/명령:** 대상·변경 계획에 대한 명시적 승인을 받은 뒤 `Apply`에 정확한 승인 문구를 입력합니다. 첫 Verify로 OCI ID/IP를 확인하고 콘솔과 대조합니다. 최초 SSH 접속 전에 해당 VM의 콘솔 boot/console history에 표시되는 SSH host fingerprint 또는 독립적으로 인증된 serial console의 `/etc/ssh/ssh_host_ed25519_key.pub` fingerprint를 확인합니다. 그 뒤 Windows SSH가 제시한 fingerprint와 비교하여 일치할 때만 등록합니다.
- **얻는 값:** VM OCID/public IP, MySQL OCID/private IP, 신뢰한 SSH host key, `verification.json`, MySQL `connection.json`.
- **넣는 파일·JSON 경로:** `%USERPROFILE%\.ssh\known_hosts`; `.local/dev/verification.json`, `.local/dev/connection.json`은 자동 생성합니다. 기존 connection은 보존하고 `connection.observed.json`과 비교합니다.
- **안전한 예시:** 아래 `$serversToTrust`에는 콘솔과 Verify가 일치한 각 서버의 실제 주소를 넣습니다. 알 수 없는 host key에 자동 yes, `StrictHostKeyChecking=no`, `ssh-keyscan` 출력만 믿는 등록을 하지 않습니다.
- **정상 결과:** VM RUNNING/AMD Micro, MySQL ACTIVE/MySQL.Free, SSH BatchMode 검사 PASS, cloud-init 완료·Docker active·OS 규칙 확인. 선택 Autonomous는 DB별 무료/20 GB/mTLS/ACL 조회 PASS, OFF면 NOT_APPLICABLE입니다.
- **실패하면 할 일:** host key 불일치는 중단하고 재생성/공인 IP 재사용/공격 가능성을 OCI OCID와 독립 경로로 확인합니다. 기존 known_hosts를 일괄 삭제하지 않습니다. agent/키 문제는 5단계, cloud-init/egress/방화벽 문제는 [OPERATIONS](OPERATIONS.md)에서 진단합니다. 적용 중단 뒤 State/실제 자원을 먼저 조회하고 자동 재apply하지 않습니다.

```powershell
# 해당 plan 적용 승인 후에만 실행
pwsh -NoProfile -File .\scripts\Apply.ps1 -Environment dev
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev
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
$serversToTrust = @(
    @{ key='server-1'; public_ip='REPLACE_WITH_VERIFIED_SERVER_1_PUBLIC_IP' },
    @{ key='server-2'; public_ip='REPLACE_WITH_VERIFIED_SERVER_2_PUBLIC_IP' }
)
# 두 서버 각각 콘솔 OCID/IP/host fingerprint를 독립 확인한 뒤 아래 반복을 진행
foreach ($server in $serversToTrust) {
    Write-Host "지금 확인할 서버: $($server.key), IP=$($server.public_ip)"
    # 이 서버의 콘솔 fingerprint와 SSH 프롬프트 값을 비교하고 일치할 때만 yes
    & "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshFirstArgs "ubuntu@$($server.public_ip)" true
    if ($LASTEXITCODE -ne 0) { throw "SSH host 등록/접속 실패: $($server.key). 전체 Verify 전에 해결하세요." }
    pwsh -NoProfile -File .\scripts\Test-SshReady.ps1 -SshPrivateKeyPath $sshKey -Address $server.public_ip -KnownHostsPath $knownHosts
    if ($LASTEXITCODE -ne 0) { throw "SSH 사전검사 실패: $($server.key)" }
}
# 구성된 모든 서버의 등록과 Test-SshReady가 끝난 뒤 전체 Verify
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev -SshPrivateKeyPath $sshKey -KnownHostsPath $knownHosts -CheckExternalPorts
```

기본 구성은 **server-1과 server-2 두 서버 각각** OCI 콘솔의 OCID·public IP·host fingerprint 확인 → known_hosts 등록 → Test-SshReady 성공을 마쳐야 합니다. 서버 1개만 등록하고 전체 Verify를 실행하면 두 번째 서버는 정상적으로 거부됩니다. 실제로 서버 1개만 구성한 경우에만 위 배열을 그 서버 하나로 맞춥니다. 처음 등록 명령은 `ask`로 직접 비교하며, Verify와 같은 Windows agent·공개키·known_hosts를 지정하고 `-F none`으로 사용자/시스템 SSH 설정의 HostName·ProxyCommand·IdentityAgent 변경 영향을 배제합니다. 개인키 파일을 subprocess에 지정하지 않고 agent의 해당 `.pub` 신원을 선택합니다.

독립 인증된 VM console에서 fingerprint를 구할 때는 `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256`를 사용합니다. 콘솔이 없거나 fingerprint를 독립적으로 확인할 수 없으면 먼저 신뢰 경로를 확보합니다. SSH 22만 연결되고 3306/6379/8080/8000에 연결되지 않는 관찰은 한 접속원에서의 검사입니다. NSG/security list/OS/Docker publish 상태도 같이 검토합니다. Autonomous wallet 다운로드·SQL 접속은 Verify가 수행하지 않으며 `NOT_RUN`으로 남습니다.

## 10. MySQL tunnel·PEM 수집·TLS 검증 준비

- **지금 하는 일:** 확인한 VM을 통해 private DB에 연결하고 TLS 신뢰를 준비합니다. DB 로그인/SQL 변경 전에 인증서만 수집할 수 있습니다.
- **실행 위치:** Windows 저장소 루트, 독립 검증한 SSH VM, OCI MySQL → DB System → Connections/Network. DB 공개 endpoint를 만들지 않습니다.
- **클릭/명령:** OCI DB OCID/private endpoint와 VM OCID/host key를 먼저 대조합니다. 아래 인증서 수집 helper와 tunnel 명령을 사용합니다. helper는 확인한 SSH 경로를 거쳐 VM의 OpenSSL에서 MySQL STARTTLS로 인증서만 받고 로그인/SQL을 하지 않습니다. VM의 OpenSSL에 해당 기능이 없으면 진단 후 중단하며 지원을 가정하여 통과하지 않습니다. Windows에 OpenSSL/Python을 추가 설치할 필요는 없습니다.
- **얻는 값:** candidate PEM, subject/issuer/SAN/만료일, DER certificate fingerprint와 **PEM 파일 SHA256**, 실제 DB endpoint 및 수집 경로. 인증서를 받았다는 사실만으로 신뢰된 것은 아닙니다.
- **넣는 파일·JSON 경로:** `.local/dev/mysql-server.pem`과 `.local/dev/mysql-server.pem.json` 수집 보고서; `.local/dev/connection.json`의 대상 ID는 유지하여 `.local/dev/connection.tunnel.json`에 복사합니다. `mysql_hostname`/`mysql_port`만 아래 TLS 방식에 맞게 수정합니다.
- **안전한 예시:** 기본 VERIFY_IDENTITY는 신뢰한 issuer CA와 인증서 SAN에 실제 존재하는 hostname이 필요합니다. self-signed SYSTEM 인증서의 explicit pinned VERIFY_CA는 확인한 SSH/OCI 경로와 파일 hash를 사용자가 검토·승인한 때만 선택합니다.
- **정상 결과:** 원격 수집 내용과 로컬 PEM hash가 일치하고 만료/체인/대상 경로를 확인했습니다. 뒤의 Verify-Database가 실제 TLS cipher·권한을 확인하기 전까지 DB 연결은 미검증입니다.
- **실패하면 할 일:** 신뢰 근거·issuer/CA·hostname·만료일 또는 경로를 확인할 수 없으면 멈춥니다. `REQUIRED`/`PREFERRED`/TLS OFF로 우회하지 않습니다. 후보 leaf만 있는 CA 체인이라면 CA를 관리자가 인증한 경로로 따로 받아야 합니다. 파일을 새로 수집해 자동 신뢰하지 않습니다.

```powershell
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
pwsh -NoProfile -File .\scripts\Get-MySqlCertificate.ps1 -Environment dev -ServerKey server-1 -SshPrivateKeyPath $sshKey
Get-FileHash -LiteralPath .\.local\dev\mysql-server.pem -Algorithm SHA256
```

helper는 검증된 SSH 연결에서 얻은 PEM을 로컬로 저장하고 `.local/dev/mysql-server.pem.json`에 인증서 정보·hash·후보 상태를 남깁니다. 기존 파일이 있으면 덮어쓰지 않고 새 `-OutputPath`를 지정하도록 요구합니다. helper는 기본 SYSTEM 인증서 1개 경로를 다룹니다. 여러 인증서가 나오면 `CERT_CHAIN_REVIEW_REQUIRED`로 중단하므로 CA chain은 관리자에게 인증된 경로로 별도 확보합니다. `CERT_OPENSSL_UNSUPPORTED`이면 VM의 OpenSSL 버전/기능을 확인하며 자동 설치나 TLS fallback을 하지 않습니다. OpenSSL이 있는 신뢰한 VM에서는 `openssl x509 -in <PEM경로> -noout -subject -issuer -dates -fingerprint -sha256 -ext subjectAltName`로 추가 확인할 수 있습니다. DER fingerprint와 PEM 파일 hash는 서로 다른 값입니다. `-ExpectedCaFileSha256`에는 **검토한 PEM 파일의 hash**를 넣습니다. 로컬에서 방금 계산한 hash를 근거 없이 승인하지 않습니다. 신뢰한 OCI 대상/SSH host key와 실제 VM→DB private 경로가 맞는지 먼저 확인해야 합니다.

Windows **별도 창**에서 tunnel을 유지합니다. 아래 변수는 9단계 결과와 콘솔에서 확인한 값입니다.

```powershell
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
$knownHosts = (Join-Path $HOME '.ssh\known_hosts').Replace('\','/')
$vmIp = 'REPLACE_WITH_VERIFIED_VM_PUBLIC_IP'
$mysqlPrivateIp = 'REPLACE_WITH_VERIFIED_MYSQL_PRIVATE_IP'
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

Windows 13306은 loopback에만 bind합니다. 창을 닫거나 Ctrl+C로 tunnel을 종료합니다. tunnel 생성 성공만으로 VM→DB 접속 성공은 확정되지 않습니다.

```powershell
if (Test-Path -LiteralPath .\.local\dev\connection.tunnel.json) { throw '기존 tunnel 설정을 보존하고 검토하세요.' }
Copy-Item -LiteralPath .\.local\dev\connection.json -Destination .\.local\dev\connection.tunnel.json
notepad .\.local\dev\connection.tunnel.json
```

**기본 VERIFY_IDENTITY:** `mysql_hostname`을 실제 인증서 SAN에 있는 DB hostname으로 유지하고 `mysql_port=13306`으로 바꿉니다. 관리자 편집기로 `%SystemRoot%\System32\drivers\etc\hosts`에 `127.0.0.1 <인증서에 실제 포함된 DB hostname>`을 추가합니다. 이름을 임의로 만들어 넣어 인증서 불일치를 우회하지 않습니다. 관리자가 인증한 경로로 받은 issuer CA/chain PEM을 기존 파일을 덮어쓰지 않고 `.local/dev/mysql-ca.pem`에 저장한 뒤, 그 관리자가 제공한 SHA256과 `Get-FileHash -LiteralPath .\.local\dev\mysql-ca.pem -Algorithm SHA256`을 대조합니다. 이 경로를 `-CaPath`에 전달합니다. `mysql-server.pem` 후보 leaf가 CA를 대신한다고 가정하지 않습니다. 기존 hosts 내용은 보존하며 tunnel 작업 종료 후 본인이 추가한 매핑만 검토하여 제거합니다.

**명시적으로 검토한 self-signed pinned VERIFY_CA:** DB 인증서가 self-signed임과 위 수집 신뢰 경로를 확인한 후에만 `mysql_hostname="127.0.0.1"`, `mysql_port=13306`을 사용합니다. 아래 11단계 명령에 `-TlsMode VERIFY_CA -ExpectedCaFileSha256 REPLACE_WITH_TRUSTED_PEM_FILE_SHA256`를 추가합니다. 기존 스크립트의 `TRUST CERTIFICATE <hash>` 승인과 SQL 변경 `BOOTSTRAP <DB OCID>` 승인은 별개입니다. VERIFY_CA는 hostname을 검증하지 않으므로 대상 보장은 확인한 SSH/OCI 경로와 고정한 PEM에 의존합니다. 인증서 교체 때는 전체 신뢰 검토를 다시 합니다.

## 11. 별도 승인된 DB bootstrap·서비스 권한 검증

- **지금 하는 일:** 논리 DB/계정 변경 계획을 검토하고 승인한 범위만 생성한 뒤 각 계정의 실제 권한을 검사합니다.
- **실행 위치:** Windows 저장소 루트, tunnel 창은 계속 실행. SQL은 확인한 private MySQL에서만 실행됩니다.
- **클릭/명령:** `databases.json`의 DB/계정을 앱 소유자와 대조합니다. Bootstrap은 읽기 TLS/기존 grant 검사를 한 뒤 대상 tenancy/region/DB OCID·DB/계정/권한 계획을 보여줍니다. 검토 후 정확한 `BOOTSTRAP <DB OCID>`를 승인한 때만 변경합니다. 이어 Verify-Database를 실행합니다.
- **얻는 값:** 생성/보존된 DB·계정, runtime DML grants, 실제 MySQL 버전/TLS cipher와 다른 서비스 DB 접근 거부 결과.
- **넣는 파일·JSON 경로:** `.local/dev/databases.json` → `databases[].name`, `databases[].username`, `databases[].host`; `.local/dev/connection.tunnel.json`의 대상/host/port. 비밀번호는 secure prompt와 암호 관리자에만 둡니다.
- **안전한 예시:** `translacat_ll`/`translacat_ll_app`, `translacat_chat`/`translacat_chat_app`. `host="%"`는 MySQL 계정 매칭이며 인터넷 ingress를 여는 설정이 아닙니다.
- **정상 결과:** 각 계정이 자기 DB에서 SELECT/INSERT/UPDATE/DELETE만 가지며 다른 서비스 DB `USE`는 1044로 거부됩니다. TLS cipher, partial_revokes=ON, 실제 버전을 확인합니다.
- **실패하면 할 일:** 기존 과도한 권한/다른 소유권은 자동 revoke/drop하지 않고 중단합니다. 중간 실패 뒤 먼저 실제 생성 상태를 읽어 확인합니다. runtime에 ALL/DDL을 부여해 해결하지 않습니다. version/드라이버 호환성은 별도로 검증합니다.

```powershell
notepad .\.local\dev\databases.json
# 기본 VERIFY_IDENTITY: 신뢰한 CA와 인증서 hostname을 10단계대로 준비한 뒤
pwsh -NoProfile -File .\scripts\Bootstrap-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-ca.pem
pwsh -NoProfile -File .\scripts\Verify-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-ca.pem
```

self-signed 신뢰 경로를 검토한 경우의 **명시적 선택 예시**입니다. 위 기본 경로 실패 시 자동 실행하는 명령이 아닙니다.

```powershell
pwsh -NoProfile -File .\scripts\Bootstrap-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-server.pem -TlsMode VERIFY_CA -ExpectedCaFileSha256 REPLACE_WITH_TRUSTED_PEM_FILE_SHA256
pwsh -NoProfile -File .\scripts\Verify-Database.ps1 -Environment dev -TargetPath .\.local\dev\connection.tunnel.json -CaPath .\.local\dev\mysql-server.pem -TlsMode VERIFY_CA -ExpectedCaFileSha256 REPLACE_WITH_TRUSTED_PEM_FILE_SHA256
```

Bootstrap은 앱 테이블을 만들지 않습니다. Flyway/EF/Exposed 등의 **DDL migration 계정과 승인된 migration 절차**는 앱별 별도 범위입니다. runtime에는 DML만 남기고 migration에 필요한 권한/일시적 자격은 별도 검토합니다. 인프라 배포 성공만으로 앱·도메인·HTTPS·테이블·기존 데이터 이전 완료라고 판단하지 않습니다.

## 12. 두 번째 Plan·변경·백업·복구·삭제

- **지금 하는 일:** 같은 입력에서 불필요한 변경이 없는지 확인하고 이후 운영 절차를 정합니다.
- **실행 위치:** Windows 저장소 루트, OCI 콘솔 자원/backup/청구, 기존 VM의 승인된 유지보수 세션.
- **클릭/명령:** 같은 현재 DB 암호와 설정으로 `Plan`을 다시 실행합니다. 키/IP 변경은 새 Preflight/Plan에서 NSG와 VM metadata 변경/교체를 검토합니다. 백업은 암호화 보관하고 실제 복원 계획을 검토합니다. 삭제는 별도 destroy/삭제 계획·데이터 소유자·백업·남길 volume/backup을 제시하고 승인받아야 합니다.
- **얻는 값:** no-change plan 또는 설명 가능한 diff, 복구 가능성/잔여 자원/청구 관찰 결과.
- **넣는 파일·JSON 경로:** `.local/dev/config.json`의 해당 항목만 수정. `.local/dev/target.json`, `terraform.tfstate` 및 `.terraform`/provider lock, 키, 현재 암호와 보호된 백업을 보존합니다. State는 비밀 포함 파일입니다.
- **안전한 예시:** IP 변경은 `ssh_allowed_cidr`만 갱신해도 **기존 VM OS 방화벽은 자동 갱신되지 않습니다**. 기존 SSH 세션과 serial-console 복구 경로를 유지한 별도 승인 절차가 필요합니다.
- **정상 결과:** 동일 설정 두 번째 Plan은 변경 없음이며 State가 실제 OCI 자원과 일치합니다. 백업/복원은 실행해 확인한 부분만 PASS로 기록합니다.
- **실패하면 할 일:** image/AD/map key/SSH key 변경의 교체 제안, State 누락, 다른 계정 대상이면 중단합니다. State 삭제/자동 import/자동 자원 삭제를 하지 않습니다. 기존 방화벽을 flush하거나 cloud-init을 통째로 재실행하지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\Plan.ps1 -Environment dev
```

[OPERATIONS의 OS 방화벽 변경·State 이행·backup/복구/정리](OPERATIONS.md)에 구체적인 수동 절차가 있습니다. MySQL 자동 backup은 1일이고 이 구성의 최종 backup은 `SKIP_FINAL_BACKUP`입니다. 복원은 새 DB System을 만들어 무료 1개 상한과 충돌할 수 있으므로 먼저 기존 DB를 삭제하지 않습니다. Destroy 후에도 volume·backup·IP·네트워크·State를 확인해야 하며 자동 정리 스크립트는 없습니다. Budget은 지출 차단이 아닌 알림입니다.

검증 기록에서는 **실제 로컬 실행 / mock / 정적 확인 / live 미실행**을 나눕니다. 오류 진단에는 작업명·범위·허용된 code/status/request ID만 공유하고 full stderr/SQL/State/plan/키/암호는 공유하지 않습니다. 읽기 조회/SSH timeout은 원인 확인 후 수동 재시도할 수 있지만 장시간 Apply를 짧은 공통 timeout으로 끊거나 자동 재apply하지 않습니다.

<!-- config-path: config.json:oci_profile -->
<!-- config-path: config.json:region -->
<!-- config-path: config.json:compartment_ocid -->
<!-- config-path: config.json:ssh_public_key_path -->
<!-- config-path: config.json:ssh_allowed_cidr -->
<!-- config-path: config.json:servers.server-1.availability_domain -->
<!-- config-path: config.json:servers.server-1.image_ocid -->
<!-- config-path: config.json:mysql_availability_domain -->
<!-- config-path: config.json:limit_checks -->
<!-- config-path: console-review.json:mysql_nsg_iam -->
<!-- config-path: databases.json:databases -->
