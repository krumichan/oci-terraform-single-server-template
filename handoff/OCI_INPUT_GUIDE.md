# OCI 입력값 수집 가이드

작성일: 2026-09-27

이 문서는 Codex 구현 전에 준비할 값과 확인 방법을 정리합니다. 아직 OCI에 생성 명령을 실행하는 문서가 아닙니다. 실제 Terraform 변수명은 완성된 템플릿 README를 따릅니다.

## 1. 먼저 DB의 의미를 맞추기

| 대상 | 현재 공식 무료 안내 | 이번 권장 사용 |
|---|---|---|
| AMD VM | `VM.Standard.E2.1.Micro` 최대 2대, 각각 RAM 1 GB | 기본 서버 2대 |
| Oracle Autonomous Database | 테넌시당 최대 2개, 각각 20 GB | Oracle 엔진이 필요할 때만 선택 |
| MySQL HeatWave DB System | home region의 무료 standalone DB System 1개, 데이터/로그 50 GB 및 backup 50 GB | TranslaCat의 MySQL 유지 |
| Compute boot/block volumes | 합계 200 GB | 예시: VM boot 각 50 GB, 기존 사용량 합산 필요 |

공식 문서 근거: [S1, S2, S3, S4]. VM 1대와 MySQL DB System 1개는 서로 다른 서비스 자원입니다. MySQL.Free는 현재 2 ECPU / 8 GiB RAM으로 안내됩니다. [S3]

**MySQL DB System 1개 안에 논리 DB를 여러 개 만드는 것**은 **MySQL DB System을 여러 개 만드는 것**과 다릅니다. 예를 들어 언어학습 DB와 `translacat_chat`을 나누고 사용자·권한도 분리할 수 있지만, CPU/메모리/장애/maintenance는 같은 DB System을 공유합니다. 물리 격리가 필요하면 별도 용량·비용 검토가 필요합니다.

이름 예시는 실제 코드의 DB 이름과 다를 수 있습니다. 무료 Oracle DB 2개를 MySQL 2개로 치환하거나, 클라우드 주소만 바꾸면 Oracle 엔진에서 기존 MySQL 코드가 그대로 동작한다고 생각하면 안 됩니다.

## 2. home region과 계정 타입

### 확인할 값

- Home region: 계정 가입 때 선택한 기본 리전.
- 현재 콘솔 선택 리전: 화면 상단의 리전 선택.
- 계정 상태: Trial / Always Free / Pay As You Go 등 화면에 표시되는 값.
- Trial인 경우 크레딧/종료일: 참고용. 무료 가능 여부의 근거로 쓰지는 않음.

### 찾는 방법

1. OCI 콘솔의 프로필/테넌시 상세 또는 리전 관리 화면에서 **Home region** 표시를 찾습니다.
2. 화면 상단의 선택 리전이 home region인지 비교합니다. 콘솔에서 보고 있는 리전과 home region은 다를 수 있습니다.
3. Billing/Upgrade/계정 정보 화면에서 계정 상태를 확인합니다. 메뉴 이름이 다르면 콘솔 검색을 이용합니다.
4. 배포 리전은 처음에는 home region으로 고정합니다. 기존 템플릿의 `ap-tokyo-1`은 계정에 맞는 값이라는 증거가 아닙니다.

Compute/DB 무료 자원의 home region 제한은 공식 설명과 실제 계정 제공 상태를 확인해야 합니다. [S1, S4]

**Trial 크레딧이 있어 지금 0원인 자원과 Always Free는 다릅니다.** Trial은 최대 30일/300달러 크레딧이며, 이번 템플릿은 Trial 자원에 의존하지 않는 방향입니다. [S6]

## 3. 이미 사용 중인 무료 자원

새 계정이라고 생각하더라도 적용 전에 확인합니다. 서버를 지워도 남아 있는 boot volume이나 다른 compartment 사용분이 있을 수 있습니다.

콘솔 검색으로 다음 화면을 엽니다.

| 화면/검색어 | 기록할 내용 |
|---|---|
| Compute / Instances | VM 수, shape, 상태, 리전, compartment |
| Boot Volumes / Block Volumes | 삭제된 VM의 잔여 boot volume 포함 용량 합계 |
| Volume Backups | boot/block volume backup 수 |
| MySQL HeatWave / DB systems | 기존 DB System, shape, 상태 |
| Autonomous Database | 기존 Always Free DB 수와 상태 |
| Limits, Quotas and Usage | 해당 서비스의 limit/usage/available, 적용 scope |

가능한 모든 관련 compartment를 확인합니다. 한 compartment에서 0개라는 사실은 테넌시 전체 0개라는 뜻이 아닙니다. 화면에 보이는 quota가 충분해도 물리 host capacity는 부족할 수 있습니다. [S1]

Codex가 read-only CLI로 대신 조사하도록 할 수 있습니다. 권한 부족/누락/pagination 문제는 '빈 계정'으로 간주하지 않도록 작업 지시서에 명시해 두었습니다.

## 4. Compartment

리소스를 모아 둘 폴더와 비슷한 관리 단위입니다. 전용 compartment를 쓰는 구성을 권장합니다.

1. 콘솔 검색에서 `Compartments`를 엽니다.
2. 기존 전용 compartment가 있다면 선택하고 OCID를 복사합니다.
3. 없다면 사용자 판단으로 전용 이름(예: `translacat`)을 만들거나, Codex가 생성 가이드를 제공하도록 합니다.
4. 실제 생성은 계정의 IAM 권한이 있어야 합니다. 루트에 모든 자원을 넣는 것을 기본 해결책으로 삼지 않습니다.

기록할 항목: 이름, compartment OCID. IAM 사용자·그룹·정책 자동 생성은 기본 인프라 적용에 몰래 포함시키지 않습니다.

## 5. Terraform용 OCI API 키

**OCI API 키와 서버 SSH 키는 서로 다른 키입니다.** API 키는 클라우드 제어 요청 서명용이고, SSH 키는 VM 로그인용입니다. [S7]

### 콘솔에서 준비

1. 현재 사용자의 상세 화면을 엽니다. 프로필의 사용자 정보 또는 Identity & Security의 도메인/사용자 목록을 통해 이동합니다.
2. `API keys` → `Add API key`를 찾습니다.
3. 새 API key pair 생성 또는 이미 가진 공개키 업로드를 선택합니다.
4. 개인키는 로컬의 안전한 디렉터리에 보관합니다. 저장소 안에는 넣지 않습니다.
5. 등록 후 **Configuration file preview**를 확인합니다.

다음 정보가 한 번에 표시됩니다. [S7]

```ini
[TRANSLACAT]
user=ocid1.user.oc1..REPLACE_ME
fingerprint=REPLACE_ME
tenancy=ocid1.tenancy.oc1..REPLACE_ME
region=REPLACE_WITH_HOME_REGION
key_file=C:/Users/YOUR_USER/.oci/oci_api_key.pem
```

preview의 `region`은 당시 콘솔 선택 리전일 수 있으므로, home region과 직접 비교합니다. `key_file`은 실제 저장한 로컬 경로로 수정합니다. 기존 DEFAULT profile을 덮어쓰지 않으려면 전용 profile 이름을 사용합니다.

보통 Windows 경로는 `%USERPROFILE%\.oci\config`이며, 사용자의 설치/설정이 다르면 그 경로를 사용합니다. Terraform이 profile 기반으로 구현되면 profile 이름을 설정하고, 변수 기반이면 해당 필드로 값을 옮깁니다. 같은 값을 두 곳에 불필요하게 중복 입력하지 않는 구현을 요구합니다.

### 대화에 보내지 않을 것

개인키 파일 내용, 키 암호(passphrase), 클라우드 로그인 비밀번호, MFA 코드, 복구 코드.

OCID/fingerprint는 비밀번호는 아니지만 계정 식별 정보이므로 공개 저장소나 공개 대화에 굳이 올릴 필요가 없습니다. Codex에는 실제 값보다 로컬 profile 이름과 경로를 알려 주는 방식이 좋습니다.

## 6. VM 접속용 SSH 키

기존에 관리 중인 키를 사용할 수도 있습니다. 새로운 전용 키가 필요하면 Windows OpenSSH를 사용합니다. 다음은 PowerShell 예시이며 같은 이름의 키가 있으면 덮어쓰지 않습니다.

```powershell
$sshDir = Join-Path $HOME '.ssh'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
$keyPath = Join-Path $sshDir 'translacat_oci'
if ((Test-Path $keyPath) -or (Test-Path "$keyPath.pub")) {
    throw '같은 이름의 SSH 키가 있습니다. 기존 키를 사용하거나 다른 이름을 선택하세요.'
}
ssh-keygen -t ed25519 -C 'translacat-oci' -f $keyPath
if ($LASTEXITCODE -ne 0) { throw 'SSH 키 생성에 실패했습니다.' }
Get-Content "$keyPath.pub"
```

키 생성 중 passphrase를 설정하고 안전하게 보관합니다. SSH client가 없다면 Windows 선택적 기능에서 OpenSSH Client 설치 여부를 확인합니다.

- `translacat_oci.pub`: 공개키. VM에 등록해도 되는 값.
- `translacat_oci`: 개인키. 본인 PC에만 안전하게 보관할 값.

Terraform에는 공개키 문자열 또는 `.pub` 경로만 전달합니다. SSH 접속에 사용할 개인키 경로는 로컬 접속 스크립트에서 사용하며 State나 VM metadata에 저장할 이유가 없습니다.

## 7. SSH 허용 주소

현재 접속 환경의 **공인 IPv4**를 확인하여 `/32`를 붙입니다.

```text
예시: 203.0.113.10/32
```

위 값은 설명용 주소입니다. 실제 네트워크의 공인 주소로 교체해야 합니다. `192.168.x.x`, `10.x.x.x` 같은 PC 내부 주소를 넣지 않습니다. VPN을 쓰면 VPN 경유 공인 IP인지 확인합니다.

집/회사 네트워크가 바뀌어 SSH가 차단되더라도 곧바로 `0.0.0.0/0`로 풀지 않습니다. 관리용 IP 변경 방법을 가이드에 포함하도록 합니다.

## 8. 무료 MySQL 제공 확인

1. home region 상태에서 콘솔 검색으로 `MySQL HeatWave` 또는 DB System 생성 화면을 엽니다.
2. Always Free 선택지 또는 `MySQL.Free` shape 제공 여부를 확인합니다. 실제 생성 버튼은 아직 누르지 않습니다.
3. 기존 무료 DB 사용량, 선택 가능한 DB 버전, 데이터/backup 용량, 무료 표시를 기록합니다.
4. Production 템플릿의 유료 shape/HA를 선택한 상태가 아닌지 확인합니다. 무료 shape의 현재 스펙은 공식 Supported Shapes에서 재확인합니다. [S3]
5. 무료 옵션이 보이지 않는 경우: 화면, 리전, 계정 상태를 기록하고 원인 확인으로 진행합니다. 유료 MySQL을 대체 생성하지 않습니다.

서버용 public subnet과 별도로 MySQL은 private 접속으로 구성합니다. 노트북의 DB 도구에서는 SSH tunnel을 사용하도록 완성 템플릿이 안내해야 합니다. MySQL DB System endpoint는 기본적으로 인터넷 직접 접속 대상이 아닙니다. [S5]

## 9. 논리 DB 및 계정

다음은 예시이며 실제 애플리케이션 설정을 확인해 확정합니다.

| 용도 | 논리 DB 예시 | 사용자 예시 |
|---|---|---|
| 언어학습 | `translacat_ll` | `translacat_ll_app` |
| Chat | `translacat_chat` | `translacat_chat_app` |
| 기존 Core가 필요할 때 | 기존 DB명 확인 후 별도 입력 | Core 전용 계정 |

서비스마다 비밀번호를 따로 만들고 로컬 password manager 또는 비밀 저장 방식으로 관리합니다. 관리자 비밀번호를 모든 서비스의 접속 정보로 사용하지 않습니다.

관리자/앱 비밀번호를 채팅으로 보내지 않아도 구현은 가능합니다. 비밀번호 입력 경로와 검증 규칙은 Codex가 생성하도록 합니다.

## 10. Image OCID는 꼭 지금 찾지 않아도 됨

기존 템플릿은 image OCID를 직접 넣어야 하지만, 개선본은 리전·OS·shape에 맞는 이미지를 조회하고 한 번 선택한 OCID를 고정하도록 요구했습니다.

지금은 Ubuntu 사용 여부와 유지할 OS 버전 정도를 준비하면 됩니다. 기존 OCID의 `ap-osaka-1`을 `ap-tokyo-1`로 바꾸는 방식은 사용하지 않습니다. 최신 이미지를 매번 자동 선택해 기존 서버를 교체하지 않는지 plan에서 확인해야 합니다.

## 11. State·plan·비밀 파일

Terraform State/plan에는 DB 비밀번호 등 민감한 데이터가 들어갈 수 있습니다. `sensitive = true`는 출력 마스킹이고 암호화가 아닙니다. [S9]

실제 값이 들어간 파일은 Git 제외, 최소 권한, 안전한 저장/백업이 필요합니다. 특히 원본 ZIP의 `.gitignore`는 `terraform.tfvars` 제외가 주석 처리되어 있으므로 **실제 값을 넣기 전에 고쳐야 합니다.** 자세한 사항은 TEMPLATE_REVIEW.md에 있습니다.

Budget 알림을 설정하더라도 과금을 자동 중단시키지는 않습니다. 무료 정책 검사와 별개로 취급합니다. [S11]

## 12. 지금 답하거나 로컬에 준비할 최소 항목

```text
Home region:
계정 상태(Trial / Always Free / PAYG / 화면 표시 그대로):
기존 VM 수와 shape:
기존 boot/block volume 합계:
기존 무료 MySQL DB System 유무:
MySQL.Free 또는 Always Free 선택지 표시 여부:
기존 Always Free Autonomous DB 수:
대상 compartment 이름/OCID 또는 아직 미생성:
서버 2대의 용도(미정이면 미정):
API 인증 방식: 로컬 OCI profile / 변수 방식 / 아직 미설정
API 개인키: 로컬 경로만 준비됨 / 아직 미설정
SSH 공개키: .pub 경로 준비됨 / 아직 미설정
SSH 허용 공인 IPv4 /32:
논리 DB 이름과 용도:
Oracle Autonomous DB: 기본 미생성 / 별도 필요
```

첫 설계 확정에 가장 필요한 것은 **home region, 기존 자원 사용량, 무료 MySQL 제공 여부**입니다. 개인키/비밀번호 없이 시작할 수 있습니다.
