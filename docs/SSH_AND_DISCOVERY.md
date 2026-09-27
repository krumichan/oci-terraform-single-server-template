# 3. SSH 준비와 실제 계정 조회

[OCI 계정 준비](ACCOUNT_SETUP.md) → **SSH와 discovery** → [무료·IAM 확인과 배포](REVIEW_AND_DEPLOY.md)

**실행 위치: 저장소 폴더의 일반 사용자 PowerShell 7.**
앞 장의 실제 API 읽기 요청이 성공한 상태에서 시작합니다. 이 장에서는 서버/DB를 만들지 않습니다.

## 3-1. SSH 키 만들기 또는 기존 키 확인

API 키와 별개로 **Ubuntu 서버에 로그인할 SSH 키**를 준비합니다.
아래 예시는 본인 `.ssh/translacat_oci` 파일을 사용합니다.

```powershell
$sshTools = Join-Path $env:WINDIR 'System32\OpenSSH'
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
New-Item -ItemType Directory -Path (Split-Path $sshKey -Parent) -Force | Out-Null
if ((Test-Path -LiteralPath $sshKey) -or (Test-Path -LiteralPath "$sshKey.pub")) {
    Write-Host '기존 키 보존. 재생성하지 않습니다.'
} else {
    & "$sshTools\ssh-keygen.exe" -t ed25519 -f $sshKey -C 'translacat-oci'
    if ($LASTEXITCODE -ne 0) { throw 'SSH 키 생성 실패' }
}
```

새 키를 만드는 경우 `Enter passphrase`가 나오면 **키를 보호할 암호**를 입력합니다.
화면에 글자가 안 보이는 것이 정상입니다. 확인 질문에 같은 암호를 다시 입력합니다.
이 질문에는 `Y`가 아니라 **본인이 정한 암호**를 넣습니다. 암호를 스크립트/JSON에 저장하지 않습니다.

**완료 확인:** 다음 두 명령이 모두 `True`입니다.

```powershell
Test-Path -LiteralPath (Join-Path $HOME '.ssh\translacat_oci')
Test-Path -LiteralPath (Join-Path $HOME '.ssh\translacat_oci.pub')
```

하나만 있으면 짝이 맞는 기존 키를 먼저 확인합니다. 기존 키를 삭제해 해결하지 않습니다.

## 3-2. 공개키 경로 하나 저장

다음 명령으로 입력할 경로를 표시합니다.

```powershell
Join-Path $HOME '.ssh\translacat_oci.pub'
```

그 **경로 문자열**을 복사한 뒤:

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step SshKey
```

입력에 경로만 붙여넣고 `SAVE`합니다. 키 본문을 붙이지 않습니다.

**완료 확인:** `ssh_public_key_path` 저장. `.pub` 파일이 아니거나 개인키 본문이면 마법사가 거부합니다.

## 3-3. Windows ssh-agent 켜기

이 단계에서만 **관리자 PowerShell 7 창을 따로** 엽니다.
키 암호를 안전하게 보관하여 나중의 비대화형 접속 검사가 사용할 Windows 서비스를 설정합니다.

```powershell
Get-Service ssh-agent
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent
Get-Service ssh-agent
```

**완료 확인:** 마지막 표의 Status가 `Running`입니다.
관리자 창을 닫고 **원래 일반 사용자 창**으로 돌아옵니다. SSH 서버 서비스는 설치/실행하지 않습니다.

## 3-4. 내 키를 agent에 등록

일반 사용자 PowerShell에서:

```powershell
$sshKey = Join-Path $HOME '.ssh\translacat_oci'
& "$env:WINDIR\System32\OpenSSH\ssh-add.exe" $sshKey
& "$env:WINDIR\System32\OpenSSH\ssh-add.exe" -l -E sha256
```

암호 질문에는 3-1에서 정한 키 암호를 입력합니다.
이어서 로컬 준비 상태를 검사합니다.

```powershell
pwsh -NoProfile -File .\scripts\Test-SshReady.ps1 -SshPrivateKeyPath (Join-Path $HOME '.ssh\translacat_oci')
```

**완료 확인:** 키/agent 검사가 PASS입니다. 아직 서버가 없으므로 서버 접속 성공을 의미하지 않습니다.
`agent` 없음은 3-3, 키 없음은 3-4를 다시 확인합니다.
Windows OpenSSH와 Git Bash의 agent를 섞지 말고, 재부팅 후에도 키 등록 상태를 확인합니다.

## 3-5. 관리 PC의 공인 IPv4 확인

아래 명령은 **외부 IP 확인 서비스(ipify)**에 HTTPS 요청을 보내 공인 IPv4를 표시합니다.
서비스는 요청을 받은 IP를 알 수 있습니다. 이를 허용하지 않는 조직에서는 네트워크 관리자가 확인한
**SSH 접속의 외부 출구 IPv4**를 사용하고 이 명령을 생략합니다.

```powershell
$publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15).Trim()
"$publicIp/32"
```

**완료 확인:** 숫자 네 묶음 뒤에 `/32`가 붙은 값 하나가 나옵니다.
VPN/프록시가 HTTPS와 SSH를 서로 다르게 보내면 이 결과가 SSH 출구 주소와 다를 수 있으므로 네트워크 구성을 확인합니다.
`ipconfig`의 `192.168...` 같은 내부 주소는 사용하지 않습니다.

## 3-6. SSH 허용 주소 저장

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step SshCidr
```

3-5의 실제 값과 `/32`를 함께 입력하고 `SAVE`합니다.

**완료 확인:** `ssh_allowed_cidr` 저장. `0.0.0.0/0`, 사설 주소, 예시 주소는 거부됩니다.
지금은 처음 배포 전 설정입니다. 이미 배포한 VM의 IP 허용 범위를 변경하는 경우에는
[기존 VM 방화벽 변경 절차](OPERATIONS.md)를 함께 따라야 합니다. JSON만 바꿔도 기존 OS 방화벽이 자동 갱신되지는 않습니다.

## 3-7. 실제 계정의 후보와 기존 사용량 조회

```powershell
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev -Discover
```

이 명령은 실제 OCI에서 **리전/compartment의 자원·이미지·한도 정의·IAM 정책**을 읽습니다.
로컬 조회 파일과 대상 기록을 생성하지만 서버/DB/IAM을 변경하지 않습니다.

**완료 확인:** `DISCOVERED`가 나옵니다. **무료 PASS는 아닙니다.**
권한 오류나 미지원 조회를 빈 사용량으로 처리하지 않습니다. 실패하면 여기서 멈추고 안전한 오류 코드로 원인을 확인합니다.

생성되는 로컬 파일은 다음입니다.

| 파일 | 역할 |
|---|---|
| `discovery.json` | 실제 계정의 AD·이미지·한도·기존 자원 |
| `discovery-suggestions.json` | 각 설정에 들어갈 수 있는 후보 |
| `iam-review.json` | 읽어온 IAM 정책 검토 자료. 사람이 입력하는 파일이 아닙니다. |
| `target.json` | 이 환경이 사용할 계정/리전/compartment 고정 기록. 직접 편집·삭제하지 않습니다. |

<a id="placement"></a>
## 3-8. AD와 Ubuntu 이미지를 번호로 선택

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Placement
```

마법사가 **서버 1 AD → 서버 1 이미지 → 서버 2 AD → 서버 2 이미지 → MySQL AD** 순서로 하나씩 묻습니다.
이미지 OCID를 수동으로 복사하거나 JSON 깊숙한 경로를 찾을 필요가 없습니다.

AD는 리전 안의 배치 위치입니다. `서버 1 AD` 화면에서 콘솔에서 확인한 이름의 번호를 선택합니다.
이미지는 후보 중 사용할 **Ubuntu 22.04 또는 24.04**를 선택합니다. 같은 이미지를 두 서버에 선택해도 됩니다.
표시된 후보는 기존 discovery 결과에서 왔으며, 나중의 Preflight가 AD/AMD Micro 호환성과 boot 크기를 다시 검사합니다.

MySQL AD는 OCI **Databases → MySQL HeatWave → DB Systems → Create DB System**의 배치 위치와 대조합니다.
**MySQL.Free 선택지가 없는 AD를 무료라고 추정하지 않습니다. 생성 버튼은 누르지 않습니다.**
메뉴 이름은 계정 UI에 따라 MySQL 또는 MySQL HeatWave로 표시될 수 있습니다.

마지막 선택 요약이 맞으면 `SAVE`합니다.

**완료 확인:** `config.json` 저장. 후보 없음/계정 불일치/24시간 이상 지난 조회 파일은 거부합니다.
입력 또는 대상이 바뀌었다면 discovery부터 다시 실행하세요.

## 3-9. 한도 정의를 번호로 선택

이 단계에서는 CPU/용량의 숫자를 직접 계산해 적지 않습니다.
어떤 한도 이름을 검사할지 선택하면 이후 Preflight가 사용량과 잔여량을 조회합니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Limits
```

`amd → storage → backups → mysql` 순서로 후보를 표시합니다.
각 화면에서 OCI **Governance & Administration → Limits, Quotas and Usage**의 서비스/리전/AD와 맞는 항목을 확인하고 번호를 고릅니다.
Autonomous를 따로 켠 경우에만 해당 항목이 추가됩니다.

한도 이름은 임의 작성하지 않습니다. 마법사는 기존 코드가 허용하는 이름/설명과 **실제 조회 결과**에서만 후보를 가져옵니다.
AD별 한도는 3-8에서 고른 AD별로 행을 만들고, REGION/GLOBAL 한도에는 임의 AD를 붙이지 않습니다.
후보가 없거나 MySQL 무료 한도 의미가 불명확하면 중단합니다. 유료 한도나 큰 quota로 대체하지 않습니다.

마지막에 `SAVE`합니다.

**완료 확인:** `config.json → limit_checks` 저장. 이 단계도 무료 승인이나 잔여량 보장이 아닙니다.
기존 다른 설정/추가 속성은 보존하며, 해당 role의 한도 매핑 변경은 저장 전에 화면에 표시합니다.

## 3-10. 다음 검토 단계로 이동

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Status
```

기본 입력에 “미입력/확인 필요”가 남아 있으면 해당 단계만 다시 실행합니다.
**다음: [4. 무료·IAM 확인 후 Plan 검토](REVIEW_AND_DEPLOY.md)**

공식 근거: [Windows SSH key/agent](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement),
[ipify IPv4 API](https://www.ipify.org/). 후보/한도 형식은 이 저장소 `Preflight.ps1`과 `Inventory.psm1`을 기준으로 합니다.
