# 2. OCI에서 값 하나씩 가져오기

[PC 도구 준비](TOOLS_WINDOWS.md) → **OCI 계정 준비** → [SSH와 discovery](SSH_AND_DISCOVERY.md)

브라우저에는 OCI 콘솔을 열고, 옆에는 **저장소 폴더의 일반 사용자 PowerShell 7**을 열어 둡니다.
이 페이지에서는 서버/DB 생성 버튼을 누르지 않습니다. Compartment와 API 키는 별도의 준비 항목입니다.

화면 이름은 OCI **영문 메뉴 기준**입니다. 한국어/일본어 콘솔이나 계정 종류에 따라 표시가 다를 수 있습니다.
아래 이름이 없으면 콘솔 검색에서 해당 영문 이름을 찾아보세요. 계정 정보가 보이지 않으면 추측해서 입력하지 않습니다.

## 2-1. Home Region만 찾고 저장하기

1. OCI 콘솔 위쪽의 **현재 리전 이름**을 누릅니다.
2. 열린 메뉴에서 **Manage Regions**를 누릅니다.
3. 표에서 **Home**으로 표시된 행 하나를 찾습니다. 현재 선택된 리전과 다를 수 있습니다.
4. 그 행의 **Region Identifier**를 복사합니다. `ap-tokyo-1` 같은 코드입니다.
   `Japan East (Tokyo)` 같은 표시 이름이나 `NRT` 같은 키를 넣지 않습니다.

표에서 코드가 안 보이면 [Oracle 공식 리전 표](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm)의
Region Name과 Region Identifier를 대조합니다. 본인의 Home을 확인해야 하며, 예시 Tokyo를 선택하는 단계가 아닙니다.
**Subscribe는 누르지 않습니다. Home Region을 새로 만드는 것도 아닙니다.**

PowerShell에서 다음 명령 하나를 실행합니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Region
```

`입력:`에 방금 복사한 코드만 붙여넣고 Enter를 누릅니다. 저장 위치를 읽고 `SAVE`를 입력합니다.
처음 저장이면 `.local/dev/` 아래 설정 파일 3개를 만듭니다. 이미 있으면 필요한 값만 바꿉니다.

**완료 확인:** `config.json`과 `console-review.json` 저장 메시지가 나옵니다.
같은 값을 입력했다면 “파일을 변경하지 않았습니다”가 정상입니다.
이 단계에서는 OCID, 결제 상태, 서버 사용량을 찾지 않습니다.

## 2-2. Tenancy OCID만 찾고 저장하기

Tenancy는 이번 OCI 계정 전체를 가리키는 식별자입니다. API 사용자나 서버의 식별자와 다릅니다.

1. OCI 오른쪽 위 **Profile(사람 모양 아이콘)**을 누릅니다.
2. **Tenancy: 본인 계정 이름**을 누릅니다. 콘솔 버전에 따라 Tenancy details로 표시될 수 있습니다.
3. Tenancy information/Details에서 **OCID**를 찾습니다.
4. 바로 옆 **Copy**를 누릅니다.

복사한 값은 `ocid1.tenancy.oc1..`로 시작해야 합니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Tenancy
```

값을 붙여넣고 `SAVE`로 저장합니다.

**완료 확인:** `console-review.json → tenancy_ocid`에 해당 값이 저장됩니다.
`ocid1.user...`나 `ocid1.compartment...`이면 다른 화면의 값을 가져온 것입니다.

## 2-3. 현재 계정 상태 문구만 기록하기

1. 왼쪽 위 **☰ 메뉴**를 누릅니다.
2. **Billing & Cost Management**를 엽니다.
3. **Upgrade and Manage Payment**를 엽니다.
4. 현재 계정 상태에 표시된 Free Trial / Free Tier / Pay As You Go 등의 문구를 읽습니다.
5. **Upgrade·결제 변경 버튼은 누르지 않습니다.**

이 화면을 제공하지 않는 계정에서는 **Subscriptions** 또는 계정 구독 상세에서 현재 구독/계정 상태를 확인합니다.
잔여 크레딧 숫자나 청구액 `0`을 계정 상태 대신 쓰지 않습니다. 상태가 불명확하면 이 단계는 `Q`로 취소하고 확인합니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step AccountStatus
```

화면의 상태 문구만 입력하고 `SAVE`로 저장합니다.

**완료 확인:** `console-review.json → account_status` 저장 메시지. 이 기록만으로 무료 승인이 되지 않습니다.

## 2-4. 배포 전용 Compartment 찾기 또는 만들기

Compartment는 자원을 묶어 관리하는 “상자”입니다. 이 템플릿은 계정 맨 위 root에 직접 배포하지 않습니다.

1. **☰ 메뉴 → Identity & Security → Compartments**를 엽니다.
2. 목록에 이미 이번 배포용 compartment가 있으면 그 이름을 누르고 **2-5로 이동**합니다.
3. 없다면 **Create Compartment**를 누릅니다.
4. 입력란을 아래처럼 채웁니다.

| 입력란 | 이번 새 배포용 예시 |
|---|---|
| Name | `translacat-free` |
| Description | `TranslaCat free-tier infrastructure` |
| Parent Compartment / Compartment | 본인 tenancy(root). 이는 새 상자의 부모이지 Terraform 배포 대상이 아닙니다. |
| Tags | 특별한 계정 정책이 없으면 추가하지 않습니다. |

5. 계정과 부모 위치가 맞는지 확인합니다. **Create Compartment**를 눌러 이 상자만 만듭니다.
6. 생성한 `translacat-free` 이름을 눌러 상세 화면을 엽니다.

**완료 확인:** 상세에 compartment 이름과 OCID가 보입니다. 기존 서버를 여기로 이동하지 않습니다.
생성 권한 오류면 정책을 임의로 확장하지 말고 계정 관리자에게 요청합니다.

## 2-5. Compartment OCID 하나 저장하기

방금 연 compartment 상세에서 **OCID → Copy**를 누릅니다.
`ocid1.compartment.oc1..`로 시작하는 값을 사용합니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Compartment
```

붙여넣고 `SAVE`로 저장합니다.

**완료 확인:** `config.json → compartment_ocid` 저장 메시지.
`ocid1.tenancy...`가 거부되는 것은 정상입니다. 2-2의 값을 다시 넣지 마세요.

## 2-6. API 개인키를 보관할 폴더 열기

API 키는 Terraform/OCI CLI가 계정에 요청할 때 쓰는 키입니다. 나중의 SSH 키와는 **별개**입니다.
먼저 일반 사용자 PowerShell에서:

```powershell
$ociHome = Join-Path $HOME '.oci'
New-Item -ItemType Directory -Path $ociHome -Force | Out-Null
explorer $ociHome
```

**완료 확인:** 본인 사용자 폴더 아래 `.oci`가 탐색기에 열립니다.
기존 키가 있으면 삭제·덮어쓰기하지 않습니다. 개인키 본문을 채팅이나 JSON에 붙여넣지 않습니다.

## 2-7. API 키 등록하기

1. OCI 오른쪽 위 **Profile → My profile**을 누릅니다.
2. **API keys** 탭/목록을 엽니다.
   안 보이면 **Identity & Security → Domains → 본인 Domain → Users → 본인 사용자 → API keys**로 이동합니다.
3. 기존 전용 키를 재사용하는 경우 등록된 키와 로컬 개인키가 짝이 맞는지 확인하고 2-8로 갑니다.
4. 새 키가 필요하면 **Add API key**를 누릅니다.
5. **Generate API key pair**를 선택합니다.
6. **Download private key**를 누릅니다. 파일이 보관됐는지 확인하기 전에는 창을 닫지 않습니다.
7. 다운로드한 `.pem`을 2-6에서 연 `.oci` 폴더로 옮깁니다.
8. 이 문서의 새 키 예시는 `translacat_api_key.pem`이라는 이름을 사용합니다.
   같은 파일이 이미 있으면 덮어쓰지 말고 다른 새 이름을 사용한 뒤 이후 경로도 맞춥니다.
9. OCI 화면으로 돌아와 **Add**를 누릅니다. 공개키가 사용자 계정에 등록됩니다.

**완료 확인:** **Configuration File Preview**가 표시됩니다. 이 화면을 다음 단계까지 열어 둡니다.
이미 등록한 키는 행의 **⋯ → View configuration file**에서 미리보기를 다시 엽니다.

## 2-8. API 설정 파일 열기

PowerShell에서:

```powershell
$configPath = Join-Path $HOME '.oci\config'
if (-not (Test-Path -LiteralPath $configPath)) { New-Item -ItemType File -Path $configPath | Out-Null }
notepad $configPath
```

기존 설정이 있으면 지우지 않습니다. 특히 기존 `[DEFAULT]`는 보존합니다.

1. 미리보기의 텍스트를 **새 section**으로 붙여넣습니다.
2. 새 section 첫 줄 `[DEFAULT]`만 `[TRANSLACAT]`으로 바꿉니다.
3. 이미 `[TRANSLACAT]`이 있으면 중복 추가하지 말고 기존 section의 키가 이번 것과 맞는지 확인합니다.
4. `user`, `fingerprint`, `tenancy`는 미리보기에서 받은 그대로 둡니다.
5. `region`은 **2-1에서 확인한 Home Region 코드**로 맞춥니다. 미리보기의 현재 리전이 Home과 다를 수 있습니다.
6. `key_file`만 `.oci`에 보관한 개인키의 **실제 절대 경로**로 바꿉니다.

경로를 정확히 확인하려면 **별도 PowerShell**에서 다음을 실행해 나온 전체 경로를 사용합니다.

```powershell
Join-Path $HOME '.oci\translacat_api_key.pem'
```

설정 형식은 아래와 같습니다. 아래의 한글 설명을 값으로 복사하지 않습니다.

```ini
[TRANSLACAT]
user=미리보기의_user_값
fingerprint=미리보기의_fingerprint_값
tenancy=미리보기의_tenancy_값
region=2-1에서_저장한_Home_Region_코드
key_file=보관한_개인키의_실제_절대경로
```

`key_file` 경로는 `/`로 구분해도 됩니다. 따옴표나 개인키 본문을 넣지 않습니다.
Ctrl+S로 저장하고 메모장을 닫습니다. 파일 이름은 `config`이며 `config.txt`가 아닙니다.

**완료 확인:** 아래 명령이 `True`를 표시합니다.

```powershell
Test-Path -LiteralPath (Join-Path $HOME '.oci\config')
```

## 2-9. 개인키 파일 하나의 Windows 접근 권한 제한

**일반 사용자 PowerShell**에서 본인이 소유한 새 키 한 파일만 대상으로 합니다.
조직의 공유/관리 키에는 이 절차를 자동 적용하지 않습니다.

먼저 경로를 확인합니다. 다른 이름으로 보관했다면 마지막 파일명만 바꿉니다.

```powershell
$apiKey = Join-Path $HOME '.oci\translacat_api_key.pem'
Get-Item -LiteralPath $apiKey | Select-Object FullName,Length
```

**지금 표시된 정확한 개인키 한 파일**에 본인만 접근하도록 제한하는 명령입니다.
경로가 맞을 때만 같은 창에서 실행합니다.

```powershell
$apiKeyAcl = Get-Acl -LiteralPath $apiKey
$apiKeyAcl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($apiKeyAcl.Access)) { [void]$apiKeyAcl.RemoveAccessRuleSpecific($rule) }
$apiKeySid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$apiKeyAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($apiKeySid,'FullControl','Allow'))
Set-Acl -LiteralPath $apiKey -AclObject $apiKeyAcl
(Get-Acl -LiteralPath $apiKey).Access | Select-Object IdentityReference,FileSystemRights,IsInherited
```

**완료 확인:** 본인 계정의 권한만 표시됩니다. 다른 파일이나 키 내용은 바꾸지 않습니다.
암호화된 기존 API 키를 사용한다면 암호를 제거하지 말고 [기존 API 인증 운영 절차](OPERATIONS.md)를 확인합니다.
SSH agent는 API 키 암호를 처리하는 도구가 아닙니다.

## 2-10. profile 이름 저장

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Profile
```

`TRANSLACAT`을 입력하고 `SAVE`합니다. 이미 같은 값이면 Enter로 유지합니다.
이 마법사는 `.oci/config`를 대신 작성하거나 개인키를 변경하지 않습니다.

**완료 확인:** `config.json → oci_profile`이 `TRANSLACAT`입니다.

## 2-11. 실제 계정에 읽기 요청 한 번 보내기

저장소 폴더에서 아래 블록을 실행합니다. 앞에서 저장한 값을 자동으로 읽으므로 OCID를 다시 붙일 필요가 없습니다.

```powershell
$settings = Get-Content -Raw .\.local\dev\config.json | ConvertFrom-Json
$review = Get-Content -Raw .\.local\dev\console-review.json | ConvertFrom-Json
oci --profile $settings.oci_profile --auth api_key --region $settings.region iam region-subscription list --tenancy-id $review.tenancy_ocid --all
if ($LASTEXITCODE -ne 0) { throw 'API 인증/조회 실패. 다음 단계로 가지 말고 아래 오류 안내를 확인하세요.' }
```

**완료 확인:** JSON에 본인 Home Region의 `region-name`과 `is-home-region: true`가 보입니다.
서버/DB를 만드는 요청은 아닙니다. 응답의 Home과 2-1 값이 다르면 여기서 멈춥니다.

`NotAuthenticated`라면 등록한 키와 `user/fingerprint/key_file` 짝 및 PC 시각을 확인합니다.
`NotAuthorizedOrNotFound`라면 Tenancy OCID·Home Region·조회 권한을 확인합니다.
오류 해결을 위해 API 암호나 개인키 본문을 공유하지 않습니다.

**다음: [3. SSH 준비와 실제 계정 조회](SSH_AND_DISCOVERY.md)**

공식 화면 근거: [리전 관리](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingregions.htm),
[Tenancy OCID](https://docs.oracle.com/en-us/iaas/Content/GSG/Tasks/contactingsupport_topic-Locating_Oracle_Cloud_Infrastructure_IDs.htm),
[Compartment 생성](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingcompartments.htm),
[API 키와 미리보기](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm),
[결제/계정 화면](https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/changingpaymentmethod.htm).
