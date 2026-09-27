# OCI Always Free 배포·접속·복구 가이드

이 문서는 `oci-terraform-single-server-template`의 PowerShell 실행 경로를 설명한다. 시작점은 [저장소 README](../README.md)와 [처음 배포하기](GETTING_STARTED.md), 공식 정책 근거와 확인일은 [SOURCES.md](SOURCES.md)다. 실제 계정 값, State, plan, 인증서는 공개 문서에 넣지 않는다.

## 1. 무엇을 만드는가

기본은 AMD/x86 Ubuntu VM 2대와 private MySQL DB System 1개다. MySQL 안에는 서비스별 논리 database와 전용 계정을 별도 bootstrap 단계에서 만든다. Chat은 `translacat_chat`, 언어학습은 설정한 별도 database를 쓴다. 논리 database가 분리되어도 CPU·메모리·장애·maintenance·물리 backup은 한 DB System에서 공유된다. 서버의 앱 역할은 고정하지 않는다.

| 자원 | 템플릿 기본값 | 실행 전에 검사하는 무료 한도 |
|---|---|---|
| AMD VM | `VM.Standard.E2.1.Micro` 2대 | 테넌시의 기존 AMD Micro를 포함하여 최대 2대 |
| VM boot volume | 각각 50 GB, Balanced | 기존 boot/block 및 분리 보존 volume을 포함하여 200 GB |
| Compute volume backup | 새 backup policy 자동 생성 없음 | 기존 boot/block backup 합계 최대 5개 |
| MySQL | `MySQL.Free` 1개, standalone, 50 GiB | Commercial realm·home region, 기존 무료 DB를 포함하여 1개 |
| MySQL backup | 서비스가 제공하는 자동 backup 1일 | 기존 잔여 backup과 신규 DB당 50 GiB 보수적 예산의 합계가 50 GiB 이하 |
| Autonomous | 기본 0개, 별도 선택 | 기존 Always Free DB를 포함하여 최대 2개, 각각 20 GB |

한도 근거는 [Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm), [MySQL 상세](https://docs.oracle.com/en-us/iaas/mysql-database/doc/features-mysql-heatwave-service.html), [Autonomous 상세](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-always-free.html)다. 실제 account·region·usage를 확인하기 전에는 이 표만으로 무료 판정을 하지 않는다.

MySQL OFF는 서버만 쓰는 신규 환경을 위한 선택이다. 이미 생성한 환경에서 OFF로 바꾸면 삭제 계획이 될 수 있다. VM key 삭제, Autonomous 개수 축소, image 변경도 마찬가지로 plan을 먼저 확인한다. 이 템플릿은 ARM·유료 shape·계정 upgrade를 자동 대안으로 사용하지 않는다.

VM당 RAM 1 GB이므로 전체 TranslaCat 서비스가 모두 잘 동작한다고 보장하지 않는다. 이미지 빌드는 별도 개발 PC/CI에서 수행하고 필요한 앱만 배치한다. 앱 저장소 수정, DNS 전환, 운영 데이터 이전 및 기존 Redis/DB 종료는 이 작업 범위에 포함하지 않는다.

## 2. 입력값을 준비하는 곳

처음 입력은 [계정값 안내](ACCOUNT_SETUP.md)의 `Setup.ps1`로 한 항목씩 저장한다. 마법사를 사용하지 않는 기존 수동 경로는 `Init-Config.ps1 -Environment dev`로 예제를 복사한다. 실제 변수 이름은 생성된 `.local/dev/config.json`을 기준으로 입력한다. 환경 이름은 State와 증거 파일을 분리하는 이름이며, 같은 환경 파일을 다른 tenancy·region용으로 재사용하지 않는다.

| 필요한 값 | 필요한 이유 | OCI 콘솔에서 찾는 위치 | 로컬 입력/설정 위치 | 비밀 정보 여부 |
|---|---|---|---|---|
| tenancy OCID | 잘못된 계정 배포 방지, 전체 사용량 조사 | 프로필 → Tenancy details → OCID | 전용 OCI profile `tenancy`, `.local/dev/console-review.json`의 `tenancy_ocid` | 비밀번호 아님, 계정 식별 정보 |
| API user OCID·fingerprint | 요청 서명 주체 확인 | 사용자 상세 → API keys → Configuration file preview | `%USERPROFILE%\.oci\config`의 전용 profile | 비밀번호 아님, 식별 정보 |
| API 개인키 경로·필요시 passphrase | Terraform/OCI CLI 인증 | API keys 등록 시 본인 PC에 저장 | OCI profile `key_file`; passphrase는 보호된 로컬 인증 설정 | 개인키·passphrase는 비밀 |
| profile 이름 | 기존 DEFAULT를 덮어쓰지 않고 인증 재사용 | 콘솔 값 아님, 로컬에서 선택 | config의 `oci_profile`, 예: `TRANSLACAT` | 아니오 |
| home region·배포 region | 무료 home region 제한 검사 | Tenancy details/Manage regions의 Home region, 상단 region selector | config와 console-review의 `region`; 실제 home region은 API 조회 | 아니오 |
| 계정 상태와 당일 무료 확인 | Trial/PAYG/Always Free 구별 | Billing/Account management의 현재 표시, 무료 자원 생성 화면 | `.local/dev/console-review.json` | 계정 운영 정보 |
| 전용 compartment OCID | 대상 격리 및 권한 확인 | Identity & Security → Compartments | config의 `compartment_ocid` | 식별 정보 |
| AMD와 MySQL의 AD | 무료 shape limit가 있는 AD 선택 | 생성 화면 Placement 및 Limits, Quotas and Usage | `servers.<key>.availability_domain`, `mysql_availability_domain`, `limit_checks` | 아니오 |
| 기존 자원 목록·한도 | 다른 compartment·리전·잔여 volume을 포함한 무료 계산 | Compute, Boot/Block Volumes, Backups, MySQL, Autonomous, Limits | Preflight가 수집하는 로컬 증거; 콘솔 확인은 console-review | 운영 메타데이터 |
| 정확한 limit 이름·scope | 사용할 수 없는 한도/잘못된 서비스 한도 적용 방지 | Limits, Quotas and Usage; Preflight discovery 결과 | config의 `limit_checks` | 아니오 |
| 고정 image OCID·OS 버전 | region·shape·x86·최소 volume 검증, 자동 교체 방지 | Compute 생성 → Image → 공식 Ubuntu LTS image | `servers.<key>.image_ocid`; discovery 후보 중 하나를 선택하여 고정 | 아니오 |
| SSH 공개키 `.pub` 경로 | VM 로그인용 공개키 등록 | 콘솔에서 발급할 필요 없음; 로컬 OpenSSH로 준비 | config의 `ssh_public_key_path` | 공개키는 비밀 아님 |
| MySQL NSG IAM 그룹·정책 OCID와 검토 근거 | DB resource principal의 VNIC/NSG 연결 전제 | Identity & Security → Domains → Groups / Policies (root·ancestor·대상 scope) | `.local/dev/console-review.json` → `mysql_nsg_iam`; 조회 결과 `iam-review.json` | 식별·권한 메타데이터, 비밀번호 아님 |
| SSH agent 등록된 공개키 fingerprint | passphrase 키의 비대화형 Verify | Windows OpenSSH ssh-agent/ssh-add (콘솔 값 아님) | Windows agent; `Test-SshReady.ps1 -SshPrivateKeyPath` | fingerprint는 비밀 아님, private key/passphrase는 비밀 |
| SSH 개인키 경로 | SSH/tunnel 연결 | 콘솔에 업로드하지 않음 | 접속/검증 명령의 로컬 경로 | 개인키는 비밀 |
| 관리용 공인 IPv4/CIDR | SSH를 본인 접속원에 제한 | 현재 집/회사/VPN의 공인 IP; OCI 값 아님 | config의 `ssh_allowed_cidr`에 실제 공인 IPv4 `/32` | 위치/네트워크 정보 |
| 서버 key·설명 | 배열 순서가 아닌 안정된 식별자로 관리 | 사용자가 정함 | `servers` map; `servers.<key>.role`은 기본 `미정`인 역할 설명 | 아니오 |
| MySQL 관리자 이름·비밀번호 | 인프라 생성 및 별도 bootstrap | 사용자가 새로 정함 | `mysql_admin_username`; 비밀번호는 Plan/DB 단계 secure prompt | 비밀번호는 비밀 |
| 서비스 DB·계정 이름 | Chat/언어학습 등 데이터·권한 분리 | 앱 설정의 DB명과 대조 | `.local/dev/databases.json`의 `databases[].name/username/host` | 이름은 비밀 아님 |
| 서비스별 서로 다른 비밀번호 | 관리자 계정 공유 방지 | 사용자가 password manager로 관리 | bootstrap의 secure prompt | 비밀 |
| 신뢰한 MySQL CA/인증서 파일 및 인증서 host | DB 서버 TLS 인증 검증 | 승인된 DB endpoint와 인증서/신뢰 경로 확인 | DB 명령의 `-CaPath`, `.local/dev/connection.json`의 `mysql_hostname` | 공개 인증서, 무결성 중요 |
| 선택 Autonomous 이름·ACL·관리자 비밀번호 | 별도 Oracle 엔진, mTLS 접속 | Autonomous 생성 화면의 Always Free/지원 버전·접근 제어 | `autonomous_databases`와 secure prompt; wallet은 로컬 보호 경로 | password/wallet은 비밀 |

콘솔 메뉴 번역과 위치는 변경될 수 있으므로 영문 서비스명을 콘솔 검색에 입력해도 된다. OCID는 비밀번호가 아니지만 공개 로그에 게시할 이유가 없다. 개인키, DB 비밀번호, MFA, 복구 코드, wallet을 대화나 Git에 붙여 넣지 않는다.

### API 키와 SSH 키

API 키는 클라우드 관리 요청을 서명하고, SSH 키는 VM에 로그인한다. 같은 키를 서로 대신 사용하지 않는다. API key 등록 후 Configuration file preview를 전용 profile에 추가하며 기존 profile을 보존한다. preview의 region은 당시 콘솔 선택값일 수 있으므로 home region을 다시 확인한다. [공식 API 키 안내](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm)

```ini
[TRANSLACAT]
user=ocid1.user.oc1..REPLACE_ME
fingerprint=REPLACE_ME
tenancy=ocid1.tenancy.oc1..REPLACE_ME
region=REPLACE_WITH_HOME_REGION
key_file=C:/Users/YOUR_USER/.oci/oci_api_key.pem
```

새 SSH 키가 필요할 때 Windows PowerShell에서 다음을 실행한다. 기존 이름이 있으면 덮어쓰지 않는다. 키 생성 시 passphrase를 설정한다.

```powershell
$sshDir = Join-Path $HOME '.ssh'
$sshKeyPath = Join-Path $sshDir 'translacat_oci'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
if ((Test-Path -LiteralPath $sshKeyPath) -or (Test-Path -LiteralPath "$sshKeyPath.pub")) {
    throw '이미 같은 이름의 키가 있습니다. 기존 키를 쓰거나 다른 이름을 선택하세요.'
}
& "$env:WINDIR\System32\OpenSSH\ssh-keygen.exe" -t ed25519 -C 'translacat-oci' -f $sshKeyPath
if ($LASTEXITCODE -ne 0) { throw 'SSH 키 생성 실패' }
```

키 생성 뒤 [SSH 키와 Windows agent 준비](SSH_AND_DISCOVERY.md)의 Windows agent 서비스 준비·일반 사용자 ssh-add 등록이 필요하다. 자동 Verify는 passphrase를 대화형으로 묻지 않는다.

## 3. Windows 첫 실행 순서

PowerShell 7.2 이상, Terraform 1.9 이상/2 미만, OCI CLI, OpenSSH를 준비한다. OCI provider는 8.5.0으로 고정하며 `.terraform.lock.hcl`을 보존한다. DB 단계에는 Oracle MySQL command-line client도 필요하다. OCI account 작업 전에는 아래 순서로 오프라인 코드 검증부터 수행할 수 있다. 명령이 실패하면 다음 단계로 넘어가지 않는다. 도구 설치는 해당 공식 배포 경로를 사용하고 저장소의 provider 고정을 임의로 최신 버전으로 바꾸지 않는다.

```powershell
Get-Location # README.md와 scripts가 있는 저장소 루트인지 확인
pwsh -NoProfile -File .\scripts\Validate.ps1 -EvidenceDirectory .\.local\validation
pwsh -NoProfile -File .\scripts\Init-Config.ps1 -Environment dev
```

Validate는 fmt/validate와 오프라인 테스트다. provider 설치·확인에는 공식 registry 접속이 필요하지만 OCI 계정 조회·apply는 수행하지 않는다. mock의 성공은 실제 OCI 자원 생성 성공을 뜻하지 않는다. Init은 `.local/dev/`에 `config.json`, `console-review.json`, `databases.json`을 만들고 기존 파일은 보존한다. Windows에서는 환경 폴더의 상속 ACL을 끄고 현재 사용자에게만 모든 권한을 허용한다. ACL 설정 실패를 무시하고 다음 단계로 진행하지 않는다.

생성된 config에 profile·region·compartment를 먼저 입력하고 discovery를 실행한다.

```powershell
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev -Discover
```

discovery가 표시하는 AD, 공식 image 후보와 limit 정의를 확인하여 config를 완성한다. 선택한 AD/image의 Compute shape 호환성과 MySQL.Free shape 제공 여부는 이어지는 일반 Preflight에서 검사한다. 최신 image를 매번 자동으로 선택하는 방식이 아니며, 첫 선택 OCID를 고정한다. Image OCID의 region 문자열만 바꿔 다른 region 이미지로 만드는 방법은 사용할 수 없다.

첫 Preflight는 `.local/dev/target.json`에 환경 이름·tenancy·region·compartment를 묶는다. 이후 값이 달라지면 중단한다. 다른 대상에는 별도 환경 이름을 사용하며 기존 target 기록이나 State를 지워 검사를 우회하지 않는다. 저장소 루트의 기존 `*.tfstate*` 또는 target 기록 없이 존재하는 환경 State가 발견되면 자동 이행하지 않는다.

OCI 콘솔과 [실행일 공식 정책](SOURCES.md)을 직접 대조한 뒤 console-review를 채운다. 무료 표시는 선택한 image/shape/region의 화면을 기준으로 확인하고, 이미 있는 다른 compartment의 리소스도 확인한다. `reviewed_on`은 당일 `YYYY-MM-DD`, `account_status`는 콘솔 표기 그대로 입력한다. `official_policy_confirmed`, `policy_conflicts_resolved`, `tenancy_wide_inspect_confirmed`, `always_free_compute_confirmed`, `limits_quotas_reviewed`와 사용할 DB의 확인 항목만 실제 확인 후 `true`로 바꾼다. 아직 확인하지 않은 항목을 `true`로 채워 검사를 우회하지 않는다. 차이가 해소되지 않았으면 `policy_conflicts_resolved`를 켜지 않고 중단한다.

```powershell
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev
pwsh -NoProfile -File .\scripts\Plan.ps1 -Environment dev
```

Preflight가 무료 여부를 확인할 수 없으면 중단하는 것이 정상이다. 권한 거절·문서 접근 실패·limit 미지원·unknown 수치를 0으로 바꾸지 않는다. Plan은 검토용 saved plan과 요약을 만들며 아직 생성하지 않는다. `terraform plan -detailed-exitcode`의 0은 변경 없음, 2는 변경 있음, 1은 실패다.

계획에서 tenancy·home region·compartment·자원 주소·shape·boot 크기·DB 옵션·기존 사용량·동시 최대 사용량과 삭제/교체를 확인한다. 예상치 못한 삭제나 교체가 있으면 승인을 입력하지 않는다. 변경 파일이나 입력값이 바뀌면 새 plan을 만들고 다시 검토한다.

인프라 적용은 사용자가 해당 계획 범위를 명시적으로 승인한 후에만 실행한다.

```powershell
pwsh -NoProfile -File .\scripts\Apply.ps1 -Environment dev
```

Apply가 보여 주는 대상과 hash를 대조하고, 표시한 승인 문구를 직접 입력한다. saved plan 적용은 Terraform 자체의 추가 확인 없이 실행될 수 있으므로 wrapper 승인을 생략하지 않는다. 이 명령은 실제 자원을 생성·변경할 수 있다. DB bootstrap 승인은 인프라 apply 승인과 별개다.

```powershell
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev -SshPrivateKeyPath "$HOME\.ssh\translacat_oci"
pwsh -NoProfile -File .\scripts\Verify.ps1 -Environment dev -CheckExternalPorts
```

`-CheckExternalPorts`는 실행하는 PC에서 각 VM 공인 IP의 TCP 22 연결을 먼저 확인한 뒤 3306·6379·8080·8000이 연결되지 않는지 검사한다. SSH 22 기준 연결도 안 되면 비노출 PASS로 판정하지 않는다. 이 검사는 그 시점·접속원에서의 도달성만 확인하므로 NSG·OS INPUT·Docker DOCKER-USER 규칙의 정확성을 대신 증명하지 않는다. 프로세스가 아직 listen하지 않아서 연결이 실패할 수도 있다. 443 서비스 상태는 이 옵션의 검사 범위가 아니다.

배포·접속 검사 후 같은 입력으로 Preflight와 Plan을 다시 실행한다. 설명할 수 없는 변경/교체가 없어야 한다. 서비스가 강제 갱신하는 DB 버전처럼 의도된 차이가 있어도 내용을 확인하고 기록한다.

## 4. 무료 검사와 계정 권한

Preflight는 구독된 region과 root·하위 compartment의 관련 자원을 조사한다. root의 compartment 목록 조회 성공은 모든 자원의 열람 권한을 뜻하지 않는다. 한 compartment라도 조회를 거절하거나 목록을 끝까지 수집하지 못하면 전체 무료 사용량은 미확인이다. 중지된 VM, 실패/삭제 진행 중 리소스, 삭제된 VM에서 남은 boot volume과 backup을 빼고 계산하지 않는다.

예상되는 읽기 권한 범위는 compartments/regions/availability domains, Compute instance·image·shape, boot/block volume·backup, MySQL DB System·shape·backup, Autonomous DB, limits이다. 하나의 대상 compartment 권한만으로 테넌시 전체 무료 잔여량을 증명할 수 없을 수 있다. 필요한 읽기 권한은 계정 관리자가 검토하여 부여한다. 템플릿은 사용자·그룹·IAM policy를 자동 생성하지 않는다.

`limit_checks`는 서비스 quota 조회를 위한 역할별 매핑이다. AMD/스토리지/backup/선택 DB에 맞는 이름과 scope를 `.local/dev/discovery.json`의 `limit_definitions` 및 콘솔에서 대조한다. 각 항목은 `role`, `service_name`, `name`, `availability_domain`을 가진다. role은 `amd`, `storage`, `backups`, `mysql`, `autonomous` 중 하나다. 사용할 모든 AD에 맞는 항목을 입력하고, REGION/GLOBAL scope는 `availability_domain: null`을 사용한다. 공개 문서에서 확인한 후보는 [SOURCES.md의 한도 표](SOURCES.md)에 있다. MySQL.Free limit의 이름을 유료 MySQL limit 이름으로 대체하면 안 된다.

다음은 JSON 형식 예시다. **그대로 실행할 값이 아니다.** AD 전체 이름과 MySQL limit 이름은 자신의 discovery 결과로 바꾼다. 두 VM이 다른 AD를 쓴다면 해당 AD의 `amd`/`storage` 항목도 각각 필요하다. 선택 Autonomous를 켜면 그 role의 항목도 추가한다.

```json
"limit_checks": [
  {"role":"amd","service_name":"compute","name":"standard-e2-micro-core-count","availability_domain":"REPLACE_WITH_FULL_AD_NAME"},
  {"role":"storage","service_name":"block-storage","name":"total-storage-gb","availability_domain":"REPLACE_WITH_FULL_AD_NAME"},
  {"role":"backups","service_name":"block-storage","name":"backup-count","availability_domain":null},
  {"role":"mysql","service_name":"mysql","name":"REPLACE_WITH_DISCOVERED_MYSQL_FREE_LIMIT","availability_domain":"REPLACE_WITH_MYSQL_AD"}
]
```

MySQL 매핑은 `mysql` 서비스의 definition 이름·설명에서 **MySQL.Free DB System 개수 한도**임을 알아볼 수 있어야 한다. 이름에 free가 있다는 것만으로 HeatWave cluster·storage·backup 한도를 선택하면 안 된다. `availability_supported`가 false인 항목밖에 없거나 이름·설명이 모호하면 이 경로는 중단한다. 임의의 비슷한 이름으로 통과시키는 대신, 실행일 공식 문서와 계정 콘솔·API의 지원 범위를 확인한 후 검사 구현을 검토한다.

무료 상한 검사는 quota 검사와 별개다. 예를 들어 PAYG 계정의 storage quota가 수십 TB이어도 무료 pool을 그 크기로 늘려 해석하지 않는다. State가 이미 관리하는 OCID를 기존 사용분과 신규분으로 중복 계산하지 않으며, 교체는 전후 리소스가 동시에 존재하는 순간을 고려한다. 무료 공간을 만들기 위해 기존 운영 리소스를 먼저 삭제하지 않는다.

MySQL은 삭제한 DB에서 보존된 무료 backup까지 합산한다. 신규 무료 DB를 만들 때 아직 사용하지 않은 backup 공간도 50 GiB 전부 필요하다고 보수적으로 계산한다. 따라서 `잔여 무료 backup 실사용량 + 신규 MySQL 수 × 50 GiB`가 50 GiB를 넘으면 차단한다. 이는 Oracle이 생성 시점에 실제로 50 GiB를 즉시 할당한다는 주장이 아니라, 자동 backup 증가를 위한 템플릿의 안전 여유다. 공간을 마련하려고 기존 backup을 자동 삭제하지 않는다.

외부 트래픽, 템플릿 밖에서 생성한 리소스, 이후 정책 변경 및 청구 반영 지연까지 이 템플릿이 통제하지는 못한다. Billing/Cost Analysis와 서비스 사용량을 주기적으로 확인한다. Budget 알림은 보조 수단이며 자동 과금 차단 기능이 아니다. [공식 Budgets 설명](https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/budgetsoverview.htm)

## 5. VM과 private MySQL 접속

Verify가 표시한 VM public IP·private IP·OCID와 MySQL private endpoint를 콘솔과 대조한다. SSH host key가 처음 보일 때는 승인된 VM인지 확인한 후 등록한다. 예상치 못한 host key 변경을 `StrictHostKeyChecking=no`로 넘기지 않는다.

Verify는 MySQL 대상 파일 `.local/dev/connection.json`이 없을 때 생성한다. 기존 파일이 있으면 보존하고 새 관측값을 `connection.observed.json`에 기록한다. DB 접속 전에 두 파일의 tenancy·region·DB System OCID와 실제 콘솔 대상을 대조한다. `-SshPrivateKeyPath` 검사는 이미 신뢰한 host key만 허용하므로 최초 SSH 연결에서 올바른 key를 확인·등록한 뒤 실행한다.

```powershell
$sshKeyPath = Join-Path $HOME '.ssh\translacat_oci'
$knownHosts = (Join-Path $HOME '.ssh\known_hosts').Replace('\','/')
$serverPublicIp = 'REPLACE_WITH_VERIFIED_VM_PUBLIC_IP'
$sshFirstArgs = @(
    '-F','none','-o','IdentityAgent=//./pipe/openssh-ssh-agent',
    '-o','IdentitiesOnly=yes','-o','GlobalKnownHostsFile=none',
    '-o',('UserKnownHostsFile="'+$knownHosts+'"'),
    '-o','StrictHostKeyChecking=ask','-o','UpdateHostKeys=no',
    '-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no',
    '-o','PreferredAuthentications=publickey','-o','ConnectTimeout=15',
    '-i',"$sshKeyPath.pub"
)
& "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshFirstArgs "ubuntu@$serverPublicIp" true
if ($LASTEXITCODE -ne 0) { throw 'SSH 연결 실패' }
pwsh -NoProfile -File .\scripts\Test-SshReady.ps1 -SshPrivateKeyPath $sshKeyPath -Address $serverPublicIp -KnownHostsPath $knownHosts
if ($LASTEXITCODE -ne 0) { throw 'SSH 사전검사 실패' }
```

기본 구성은 **server-1과 server-2 두 서버 각각** 콘솔 OCID/IP/fingerprint를 독립 확인하고 위 등록·Test-SshReady를 반복한다. 모든 서버를 준비한 뒤에만 전체 Verify를 실행한다. [가이드 9단계](GETTING_STARTED.md)에 두 서버 반복 명령이 있다. 최초 연결은 ask로 비교하며 Verify와 같은 Windows agent·공개키·known_hosts를 고정하고 -F none으로 ambient HostName/ProxyCommand/IdentityAgent 설정을 배제한다.

VM 안의 진단 명령은 Linux 명령이다. 대화형 VM 작업이 필요하면 등록 후 위 명령의 마지막 true 대신 원하는 진단 명령을 지정하거나 생략해 shell에 접속한다.

```bash
sudo cloud-init status --long
sudo systemctl status docker --no-pager
docker --version
docker compose version
sudo journalctl -u docker --no-pager -n 80
sudo tail -n 80 /var/log/cloud-init-output.log
free -h
df -h
```

cloud-init 완료와 Docker/Compose v2 확인 전에는 앱 배포를 시작하지 않는다. cloud-init 실패 시 로그의 원인을 해결하며 무작정 재초기화하거나 기존 디스크를 삭제하지 않는다. Docker 로그 rotation 설정과 재부팅 후 서비스 기동 여부도 확인한다. 앱 데이터는 컨테이너 writable layer만 믿지 말고 명시한 volume에 보관하고 별도 backup을 준비한다.

MySQL은 DB용 private subnet에서 접속한다. 로컬 DB 도구는 별도 PowerShell 창에 loopback 전용 SSH tunnel을 열어 사용한다.

```powershell
$sshKeyPath = Join-Path $HOME '.ssh\translacat_oci'
$knownHosts = (Join-Path $HOME '.ssh\known_hosts').Replace('\','/')
$serverPublicIp = 'REPLACE_WITH_VERIFIED_VM_PUBLIC_IP'
$mysqlPrivateIp = 'REPLACE_WITH_VERIFIED_MYSQL_PRIVATE_IP'
$sshTunnelArgs = @(
    '-F','none','-o','IdentityAgent=//./pipe/openssh-ssh-agent',
    '-o','IdentitiesOnly=yes','-o','GlobalKnownHostsFile=none',
    '-o',('UserKnownHostsFile="'+$knownHosts+'"'),
    '-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UpdateHostKeys=no',
    '-o','PasswordAuthentication=no','-o','KbdInteractiveAuthentication=no',
    '-o','PreferredAuthentications=publickey','-o','ConnectTimeout=15',
    '-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=30',
    '-i',"$sshKeyPath.pub",'-N','-L',"127.0.0.1:13306:${mysqlPrivateIp}:3306"
)
& "$env:WINDIR\System32\OpenSSH\ssh.exe" @sshTunnelArgs "ubuntu@$serverPublicIp"
```

로컬 DB 도구의 host는 `127.0.0.1`, port는 `13306`이다. tunnel 창을 닫으면 연결도 끝난다. Windows의 13306을 외부에 개방하지 않는다. SSH가 허용되어도 VM→DB private 통신이 허용되어 있지 않으면 tunnel의 DB 연결은 실패한다.

### TLS 인증서 신뢰

[처음부터 따라 하는 가이드 10~11단계](GETTING_STARTED.md)에 OCI 대상 확인 → 독립 SSH host key 확인 → 인증서 수집 → PEM·인증서 정보·지문 대조 → tunnel 설정 → TLS 승인 → DB 검증 명령을 연결했다. 기본은 `VERIFY_IDENTITY`이며 신뢰한 CA와 인증서 SAN의 실제 DB hostname을 확인한다. hostname을 loopback으로 해석할 때에도 인증서 이름을 유지하고 port만 13306으로 바꾼다.

기본 SYSTEM self-signed 인증서는 사용자가 OCI DB endpoint와 SSH host key를 독립적으로 확인한 다음 `Get-MySqlCertificate.ps1`로 수집할 수 있다. 이 helper는 Windows OpenSSH strict 검증을 거친 VM에서 OpenSSL MySQL STARTTLS를 사용하고 로그인·SQL은 수행하지 않는다. VM의 OpenSSL에 해당 기능이 없으면 안전한 진단을 남기고 중단하며 지원을 가정하여 통과하지 않는다. Windows에 OpenSSL/Python을 추가 설치하지 않는다. 인증서 수집 결과는 **candidate**이며 자동으로 신뢰하지 않는다. CA-signed leaf만 받은 경우 승인된 issuer CA/chain을 따로 확보한다. [OCI TLS 진단](https://docs.oracle.com/en-us/iaas/mysql-database/doc/troubleshooting-networking.html), [MySQL TLS 설명](https://docs.oracle.com/cd/E17952_01/mysql-8.4-en/using-encrypted-connections.html)

```powershell
pwsh -NoProfile -File .\scripts\Get-MySqlCertificate.ps1 -Environment dev -ServerKey server-1 -SshPrivateKeyPath "$HOME\.ssh\translacat_oci"
Get-FileHash -LiteralPath .\.local\dev\mysql-server.pem -Algorithm SHA256
```

기존 PEM 파일은 덮어쓰지 않는다. 명시적 self-signed `VERIFY_CA` 경로에서는 subject/issuer/만료일·확인한 SSH/OCI 수집 경로·PEM 파일 hash를 검토하고 `-ExpectedCaFileSha256`에 그 hash를 넣는다. DER certificate fingerprint는 PEM 파일 hash와 다르다. `TRUST CERTIFICATE <hash>`와 `BOOTSTRAP <DB OCID>`는 별개 승인이다. VERIFY_CA는 hostname을 검증하지 않으므로 그 신뢰 경로를 준비할 수 없으면 중단한다. hash 일치는 잘못된 체인·만료된 인증서를 유효하게 바꾸지 않는다. 인증서가 바뀌면 다시 검토하며 TLS를 OFF/PREFERRED/REQUIRED로 낮추지 않는다.
### 네트워크와 방화벽

SSH ingress는 관리용 CIDR만 허용한다. public 서비스가 필요하면 해당 VM의 443 등 필요한 규칙을 명시한다. 8080/8000/3306/6379를 인터넷에 자동 노출하지 않는다. 서로 다른 security list와 NSG의 허용 규칙은 합쳐질 수 있으므로 한쪽을 좁혀 놓았다는 이유만으로 안전하다고 판단하지 않는다.

VM의 OS firewall과 `docker ps`의 publish 주소도 확인한다. 내부용 서비스를 `0.0.0.0:<port>`에 잘못 publish하지 않는다. Docker는 자체 iptables 규칙을 만들므로 UFW 규칙만으로 노출 차단을 단정하지 않는다. 기존 iptables를 flush하지 않는다. public IP 없는 VM은 public subnet 안에 있다는 이유만으로 인터넷 업데이트·이미지 pull이 가능하지 않으며, 지원된 egress 경로가 없으면 구성을 바꾸기 전에 중단한다.

관리 CIDR·HTTPS·내부 포트 설정 변경은 기존 VM의 cloud-init을 다시 실행하지 않는다. Terraform의 NSG 변경과 OS 방화벽 변경이 서로 달라질 수 있으므로, 이미 배포한 VM은 관리 접속을 유지하며 별도 검토한 OS 규칙 갱신 절차가 필요하다.

기존 VM의 방화벽을 바꿀 때는 대상 VM OCID·현재/새 CIDR·포트·NSG plan·OS 규칙 diff·복구 경로를 먼저 보여주고 그 유지보수 범위에 대한 명시적 승인을 받는다. 아래는 승인 후 실행할 Linux 절차이며 이 문서를 읽었다는 사실만으로 실행 승인이 되지 않는다. 기존 SSH 세션을 열어 두고, 독립적으로 접속 가능한 OCI serial console도 준비한다.

```bash
firewallBackupPath="/usr/local/sbin/oci-free-firewall.$(date -u +%Y%m%dT%H%M%SZ).bak"
if sudo test -e "$firewallBackupPath"; then
  printf '%s\n' '같은 이름의 백업이 있습니다. 다른 이름을 사용하세요.'
elif sudo cp -a /usr/local/sbin/oci-free-firewall "$firewallBackupPath"; then
  sudoedit /usr/local/sbin/oci-free-firewall
  sudo diff -u "$firewallBackupPath" /usr/local/sbin/oci-free-firewall
  sudo bash -n /usr/local/sbin/oci-free-firewall
else
  printf '%s\n' '백업 생성 실패: 편집·적용을 중단하세요.'
fi
```

백업 생성이 실패하면 편집하지 않는다. SSH 주소 변경이라면 승인된 22번 규칙의 source CIDR만 수정하고, 443/내부 포트 변경이면 OCI-FREE-INPUT과 OCI-FREE-DOCKER의 관련 규칙을 NSG plan과 함께 검토한다. 전체 INPUT/FORWARD/DOCKER 체인을 flush하거나 DROP을 통째로 지우지 않는다. `diff`의 종료 코드 1은 변경이 있다는 뜻이며 내용 검토가 필요하다. `bash -n` 실패 시 적용하지 않는다. 승인한 diff와 문법 검사를 확인한 뒤 다음을 실행한다.

```bash
sudo systemctl restart oci-free-firewall
sudo systemctl status oci-free-firewall --no-pager
sudo iptables -S OCI-FREE-INPUT
sudo iptables -S OCI-FREE-DOCKER
```

검토·승인한 Terraform NSG 변경도 적용한 뒤 새 터미널에서 새 접속원으로 SSH 성공을 확인한다. 기존 세션은 확인이 끝날 때까지 닫지 않는다. 실패하면 보존한 세션/serial console에서 원인을 조사하고 승인한 복구 범위대로 백업 스크립트와 NSG를 복원한다. 방화벽 변경을 재적용하려고 `cloud-init clean`, cloud-init 전체 재실행 또는 재부팅을 일반적인 해결책으로 사용하지 않는다.

## 6. 서비스 database와 사용자 bootstrap

인프라 적용만으로 서비스 database·사용자·앱 테이블이 모두 생성되지는 않는다. bootstrap 설정 예제에서 database와 username을 앱 설정과 대조하고, target tenancy·region·DB System OCID·private endpoint를 인프라 출력과 일치시킨다. 관리자 계정을 앱의 공용 계정으로 쓰지 않는다.

`.local/dev/databases.json`이 없을 때만 `examples/databases.json.example`을 복사한다. 예제는 `translacat_ll`/`translacat_ll_app`과 `translacat_chat`/`translacat_chat_app`이며, 실제 앱별 설정과 다시 대조한다. 계정 host의 `%`는 인터넷 ingress를 여는 설정이 아니다. private network의 허용 범위 안에서 MySQL 계정 host 제한을 얼마나 좁힐지 별도로 검토한다.

```powershell
if (-not (Test-Path -LiteralPath '.\.local\dev\databases.json')) {
    Copy-Item -LiteralPath '.\examples\databases.json.example' -Destination '.\.local\dev\databases.json'
}
pwsh -NoProfile -File .\scripts\Bootstrap-Database.ps1 -Environment dev -CaPath 'C:\Users\YOUR_USER\.oci\mysql-ca.pem'
```

이 명령은 먼저 TLS·기존 계정·권한을 읽기 전용으로 확인하고 변경 대상을 표시한 뒤 `BOOTSTRAP <DB System OCID>` 승인을 요청한다. 정확한 target과 database/user 목록을 검토한 후 입력해야 실제 DDL/grant가 실행된다. 승인하지 않고 종료하면 bootstrap DDL을 수행하지 않는다. 비밀번호는 secure prompt에서 입력하고 콘솔 기록·환경 예제·공유 로그에 넣지 않는다. MySQL client가 PATH에 없으면 실제 실행 파일을 `-MySqlPath`로 지정한다. 관리자 권한으로 임의 패키지를 설치하거나 다른 DB client로 묵시적 fallback하지 않는다.

재실행은 기존 데이터를 DROP/TRUNCATE하거나 사용자를 삭제하거나 비밀번호를 임의로 바꾸면 안 된다. 기존 계정의 비밀번호 변경은 별도의 rotation 작업이다. 기존 DB 또는 계정과 충돌하면 그 소유권과 grant를 확인한 후 진행한다. 실패한 bootstrap을 반복할 때 이미 성공한 database/user 생성이 있을 수 있으므로 먼저 읽기 전용 verify를 실행한다.

```powershell
pwsh -NoProfile -File .\scripts\Verify-Database.ps1 -Environment dev -CaPath 'C:\Users\YOUR_USER\.oci\mysql-ca.pem'
```

완료 후 각 서비스 계정의 TLS 연결·자기 database 접근·정확한 grant와 다른 서비스 database의 `USE` 거부(MySQL 1044)를 확인한다. 권한은 자기 database의 `SELECT, INSERT, UPDATE, DELETE`에 한정한다. 스키마명에 `_`가 있어도 다른 database에 wildcard grant가 퍼지지 않도록 `partial_revokes=ON`도 확인하며, OFF이면 서버 설정을 자동 변경하지 않고 중단한다. 단순히 SQL 문자열에 database 이름이 있다는 것만으로 권한 분리를 검증했다고 하지 않는다. DB 검증이 mock이면 실제 MySQL 권한 검증은 미실행이라고 기록한다.

앱의 connection string에는 각 서비스 계정과 자기 database만 넣는다. JDBC·EF Core·Exposed 등의 TLS 옵션은 해당 드라이버 형식으로 설정하고 CA 파일을 전달한다. 실제 비밀번호를 URL 예제에 넣지 않는다. 앱 runtime 계정에는 DDL 권한이 없으므로 Flyway/EF migrations는 별도 승인한 migration 주체와 기존 서비스 절차로 실행한다. bootstrap은 앱 테이블을 대신 생성하거나 runtime 계정에 `ALL PRIVILEGES`를 부여하지 않는다.

무료 MySQL은 최신 버전으로 생성·갱신되므로 기존 MySQL 8.4와의 동일성을 보장하지 않는다. 실제 `SELECT VERSION()` 결과를 기록하고 드라이버/ORM/DDL·인증 plugin·migration을 별도 환경에서 확인한 후 운영 연결을 전환한다. 기존 앱 연결 주소를 바꾸는 것만으로 호환성 검증이 완료되는 것은 아니다.

## 7. Autonomous 선택 옵션

Autonomous는 Oracle 엔진이며 MySQL database 2개를 의미하지 않는다. 기본 OFF로 두고 Oracle 기능이 필요한 경우에만 최대 2개까지 추가한다. 무료 private endpoint는 지원되지 않으므로 MySQL private subnet 설계를 복사하지 않는다. mTLS/wallet과 ACL을 사용하고 필요한 공인 접속원만 허용한다. VM에서 접속한다면 VM의 실제 egress 주소가 ACL에 필요한지 확인한다.

wallet은 비밀 파일로 보관하며 API key나 SSH key와도 다르다. 선택한 region에서 무료 지원 버전이 확인되지 않으면 생성하지 않는다. Always Free 옵션을 유료로 전환하거나 scale up하지 않는다. 무료 인스턴스의 backup/restore 및 비활성 회수 제한은 [Autonomous 공식 문서](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-always-free.html)를 확인한다.

## 8. State와 기존 단일 서버 사용자의 이행

신규 환경은 새 State를 사용한다. 기존 리소스가 있는 환경에서 State 파일을 지우고 plan을 실행하면 중복 생성을 제안할 수 있다. State를 잃어버렸으면 생성을 중단하고 보호된 backup 복구 또는 소유권이 확인된 OCID import 계획을 수립한다. 같은 OCI 자원을 로컬 Terraform과 Resource Manager의 서로 다른 State로 이중 관리하지 않는다. 이 템플릿을 Resource Manager에 그대로 업로드하는 경로는 지원을 확인하지 않았다.

State·saved plan·plan JSON에는 비밀번호가 들어갈 수 있다. `sensitive = true`는 화면 마스킹이며 암호화가 아니다. Init/Preflight는 `.local/<환경>`의 Windows ACL을 현재 사용자로 제한한다. 별도 복사한 State·plan·backup에도 같은 보호를 적용하고 디스크 암호화 및 별도 암호화 backup을 사용한다. 환경별 `target.json`, `terraform.tfstate`, `.terraform` 경로를 함께 보존하며 API/SSH 개인키는 저장소 밖에 보관한다. [Terraform 민감값 설명](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)

기존 단일 서버 template을 사용한 이력이 있으면 새 환경 Init→Apply로 대체하지 않는다. 먼저 원본 구성, provider lock, State, 실제 리소스 OCID와 기존 미커밋 변경을 보존한다. 이전 단일 `oci_core_instance.server`의 새 후보 주소는 `oci_core_instance.server["server-1"]`이다. 이것은 주소 대응 예시이며 실행 승인이 아니다. `oci_core_vcn.main`, `oci_core_internet_gateway.public`, `oci_core_route_table.public`, `oci_core_subnet.public` 주소가 유지되어도 CIDR·DNS·security 설정 차이를 plan에서 검토한다. 이전 `oci_core_security_list.main`을 새 `oci_core_security_list.empty`로 단순 이동하면 안 된다. 규칙을 제거하는 의미 변화가 있기 때문이다.

현재 네트워크는 VCN `10.0.0.0/16`, VM subnet `10.0.1.0/24`, DB subnet `10.0.2.0/24`이며 기존 환경과 겹치면 무조건 적용하지 않는다. 자동 `moved` 블록을 추가하여 기존 State를 묵시적으로 변경하지 않는다. `moved`/import의 실제 주소는 새 구성과 기존 State를 대조하여 정확하게 작성하고, 사용자 승인 전에 `terraform state mv`/`import`/`state rm`을 실행하지 않는다. 이름만 같다고 같은 자원으로 취급하지 않는다.

image OCID 변경, AD 변경, key 변경 또는 네트워크 구조 변경은 교체를 유발할 수 있다. map의 순서 변경과 key 변경은 다르다. key 변경은 기존 서버 삭제와 새 서버 추가로 해석될 수 있으므로 rename 절차가 필요하다. 기존 데이터 디스크를 새 VM에 옮기는 작업도 별도 승인 범위다.

## 9. backup·복원·안전한 정리

무료 MySQL의 자동 backup은 1일이며 수동 backup과 PITR을 제공하지 않는다. 최종 backup은 일반 유료 DB보다 보존 기간이 짧다. 논리 dump와 앱 데이터 backup을 별도로 암호화하여 보관하고, 정상 종료·전체 테이블·복구에 필요한 사용자 grant·버전 정보를 함께 확인한다. dump 안의 개인정보·비밀도 보호한다. [MySQL backup 정책](https://docs.oracle.com/en-us/iaas/mysql-database/doc/overview-backups.html)

현재 Terraform의 삭제 정책은 삭제 보호 ON, 자동 backup `RETAIN`, 최종 backup `SKIP_FINAL_BACKUP`이다. 즉, 삭제를 별도 승인하여 보호를 해제하더라도 새 최종 backup을 자동으로 만들지 않는다. 자동 backup의 보존과 새 최종 backup 생성은 다르다. 삭제 전 최종 backup이 필요하면 무료 잔여량·보존 기간·복구 가능성을 확인하고 별도 변경 계획에 포함한다.

복원은 새 DB System을 만드는 작업이어서 현재 무료 DB가 1개 있으면 한도를 넘길 수 있다. 시험 복원을 위해 기존 DB를 먼저 삭제하지 않는다. 복원 대상, 예상 downtime, State 연결, backup 보존, 무료 조건과 명시적 승인이 확보된 별도 절차로 진행한다. 생성 직후 backup이 있다는 사실만으로 복원 성공을 보장하지 않는다. [공식 복원 설명](https://docs.oracle.com/en-us/iaas/mysql-database/doc/restoring-from-backup.html)

AMD VM은 idle 조건에 따라 회수될 수 있다. 정상적인 관측·backup·복구 준비를 사용하며, 회수 방지를 위한 허위 CPU 부하나 무의미한 반복 요청을 만들지 않는다. VM이 사라졌을 때 보존된 boot volume부터 확인하고 State를 버리거나 새 VM을 무조건 생성하지 않는다.

정리는 자동 실행하지 않는다. 순서는 다음과 같다.

1. 삭제할 tenancy·region·환경·OCID 목록과 데이터 소유자를 확인한다.
2. 검증 가능한 backup과 복구 경로, DB 최종 backup/자동 backup 보존 영향을 확인한다.
3. 필요한 리소스만 삭제할 별도 변경을 만들고 DB의 Terraform `prevent_destroy`와 서비스 삭제 보호 영향을 확인한다.
4. 정확한 destroy/삭제 plan을 검토하고, 삭제·보존 volume·backup·비용에 대해 명시적 승인을 받는다.
5. 승인된 범위만 적용하고 남은 volume·backup·public IP·네트워크와 State를 다시 대조한다.

resource 블록을 코드에서 제거하면 해당 블록의 `prevent_destroy`도 사라질 수 있다. 따라서 `prevent_destroy`만으로 모든 삭제를 막는다고 생각하지 않는다. 삭제를 위해 보호 설정을 자동 완화하는 우회 명령은 제공하지 않는다.

## 10. 오류별 대응과 검증 기록

| 오류/상황 | 다음 조치 |
|---|---|
| 인증 실패·profile 없음 | user/fingerprint/tenancy/key_file과 key 권한·시계를 확인. 개인키 내용을 출력하지 않음 |
| home region 불일치 | 콘솔 선택 region과 실제 home region 대조. 임의 region 문자열 치환 금지 |
| compartment 일부 조회 거절 | 필요한 읽기 권한과 전체 범위 확인. 미조회 자원을 0개로 간주하지 않음 |
| limit 정의/usage가 없음 | discovery·콘솔과 scope를 확인. 빈 값/404를 0으로 변환하지 않음 |
| MySQL.Free 미제공 | 계정 realm/home region/무료 limit/AD 확인 후 중단. 유료 MySQL 선택 금지 |
| 무료 수량·200 GB 초과 | 기존 자원·분리 boot volume·backup 소유권을 조사. 자동 삭제 없음 |
| image 비호환·크기 부족 | 같은 region의 공식 Ubuntu x86 후보와 shape 호환성 확인 후 OCID 고정 |
| out-of-host-capacity | 원인 기록, 무료 shape가 지원되는 AD 확인 또는 나중에 수동 재시도. 무한 재시도·upgrade 없음 |
| cloud-init/Docker 실패 | 초기화·패키지·DNS/egress 로그 확인. 기존 iptables/데이터 초기화 금지 |
| SSH timeout | 현재 공인 IP, NSG/security list, OS firewall, VM public IP 확인. SSH 전체 공개 금지 |
| DB TLS 오류 | 신뢰 파일·만료일·체인·host/SSL mode 확인. 인증서 검증 해제 금지 |
| DB 권한 오류 | 연결 계정·host pattern·자기 DB grant 확인. 관리자 계정으로 앱을 대체하지 않음 |
| stale/변경된 plan | Preflight부터 새로 수행 후 변경 계획 재검토. 이전 승인 재사용 금지 |
| 같은 설정에서 교체 제안 | image·map key·AD·provider·State 경로를 대조하고 중단 |

각 검증 결과는 다음 네 범주를 섞지 않고 기록한다.

- **실제 실행:** 로컬 fmt/init/validate, 스크립트 파싱, 정책 테스트 실행 결과 또는 승인된 live OCI 조회·연결 결과. 종료 코드와 검사 범위를 남긴다.
- **mock:** 가상 OCI/Terraform/SQL 응답으로 검증한 분기. 실제 host capacity·MySQL 권한·네트워크 성공 증거가 아니다.
- **정적 확인:** 문법/스키마/문서 링크/설정 경로를 코드와 대조한 결과. 동작 또는 실계정 성공을 뜻하지 않는다.
- **미실행:** 인증값·인프라·명시적 승인이 없어 하지 않은 apply/destroy/bootstrap 및 live SSH/DB 검증. 이유를 남긴다.

오프라인 통과 후 상태는 `IMPLEMENTED_OFFLINE_VALIDATED_LIVE_NOT_RUN`, 실제 계정 preflight/plan까지 확인하면 `LIVE_PLAN_VERIFIED_AWAITING_APPLY_APPROVAL`이다. 승인된 배포·접속 검증까지 끝난 `LIVE_DEPLOYED_INFRA_VERIFIED`도 전체 애플리케이션 운영 검증 완료를 의미하지 않는다. 실패하거나 확인하지 못한 검사를 PASS로 바꾸지 않는다.


## 11. MySQL NSG IAM·SSH agent·오류 진단 후속 기준

MySQL NSG는 사용자 그룹의 subnet/NSG/VNIC 권한 외에 DB resource principal의 NSG/VNIC 권한도 필요하다. [정책 예제](../examples/mysql-nsg-policy.txt.example)를 실제 group/compartment OCID로 검토하며 [12단계 가이드의 7단계](GETTING_STARTED.md)에 콘솔 위치·치환값·review JSON 필드·승인 경계가 있다. `Preflight -Discover`는 ancestor/root 정책 메타데이터를 읽어 `.local/dev/iam-review.json`을 기록하고 검토할 후보를 표시한다. 정책 문자열이 존재한다는 사실은 유효 권한 검증이 아니다. 일반 Preflight는 수동 확인과 정책 조회가 충족돼야 통과하며 `effective_authorization=NOT_PROVEN`을 보존한다. IAM 생성/수정 명령을 자동 실행하지 않는다.

passphrase SSH 키는 [SSH 키와 Windows agent 준비](SSH_AND_DISCOVERY.md)의 Windows ssh-agent에 일반 사용자로 등록한다. `Test-SshReady.ps1`는 서비스·실행 경로·agent fingerprint를 확인하고 선택 `-Address`에서 strict BatchMode SSH를 30초 제한으로 검사한다. `Verify -SshPrivateKeyPath`는 이를 자동 연결하고 실제 OS 확인은 300초까지 기다린다. 서비스 설정/ssh-add/known_hosts 변경은 자동으로 수행하지 않는다. `ssh`와 `ssh-add`는 같은 Windows OpenSSH 배포판을 사용한다. host key 변경은 검토 없이 삭제/재등록하지 않는다.

`Invoke-NativeTool`은 비밀이 포함될 수 있는 full stderr/SQL/State를 출력하지 않는다. 허용된 OCI code, HTTP status, 형식에 맞는 request ID, 작업명과 검증한 범위·고정된 조치 안내를 제공한다. `NotAuthenticated`는 API 서명/시간/profile, `NotAuthorizedOrNotFound`는 실제 OCID/권한, limit/capacity는 무료 잔여량/재고를 확인한다. request ID는 관리자/Oracle 지원과 원인을 추적할 때 사용하되 비밀 원문을 함께 공유하지 않는다. 읽기 OCI 조회는 120초 제한이며 취소 후 조회 상태를 확인한다. Terraform Apply는 짧은 공통 timeout을 적용하지 않으며, 사용자가 중단했다면 State/실제 자원과 새 plan을 먼저 확인하고 자동 재apply하지 않는다.

Autonomous ON이면 Verify는 State에 있는 각 DB를 OCI `autonomous-database get`으로 조회하고 OCID/region/tenancy/compartment·이름·무료 모드·20 GB·mTLS·IP ACL·scaling·상태를 검사한다. `.local/dev/verification.json`의 `autonomous.status`는 OFF `NOT_APPLICABLE`, 시작/미완료 `NOT_RUN`, 성공 `PASS`, 실패 `FAIL`이다. wallet 다운로드/Oracle SQL 실제 접속은 별도 `NOT_RUN`이며 이 API 검사가 대신하지 않는다. wallet을 얻어 실제 접속할 때는 Autonomous 콘솔 → 해당 DB → Database connection에서 대상/ACL을 확인하고 본인만 접근 가능한 위치에 저장한다. 승인되지 않은 wallet 업로드·SQL·ACL 변경을 자동 실행하지 않는다.
