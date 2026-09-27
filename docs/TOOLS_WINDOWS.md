# 1. PC 도구 준비

[처음 시작하기](GETTING_STARTED.md) → **PC 도구 준비** → [OCI 계정 준비](ACCOUNT_SETUP.md)

**이미 PASS인 도구는 건드리지 않습니다.** Docker가 있어도 `mysql.exe`가 생기지는 않지만,
MySQL 클라이언트는 아직 필요하지 않습니다. 서버에 접속한 뒤 DB 단계에서 준비합니다.

<a id="powershell"></a>
## 1-1. PowerShell 7 열기

**실행 위치: 지금 사용 중인 Windows PowerShell. 관리자 실행은 필요할 때만 승인합니다.**

먼저 확인합니다.

```powershell
pwsh --version
```

`PowerShell 7.2` 이상의 버전이 나오면 설치하지 말고 1-2로 이동합니다.
`pwsh`를 찾지 못하면 **이 명령 하나**를 실행합니다.

```powershell
winget install --id Microsoft.PowerShell --exact --source winget --installer-type wix
```

설치가 끝나면 터미널을 닫습니다. VS Code 터미널이었다면 VS Code도 다시 엽니다.
시작 메뉴에서 **PowerShell 7**을 검색해서 열고 `pwsh --version`을 다시 실행합니다.
Windows 기본 PowerShell 5.1은 삭제하지 않습니다.

**완료 확인:** `PowerShell 7.x.x`가 보입니다. 보이지 않으면 여기서 멈춥니다.

<details><summary>winget도 없거나, 설치했는데 pwsh를 못 찾는 경우</summary>

`winget`이 없으면 [Microsoft MSI 설치 안내](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows#install-the-msi-package)의
안정 버전 Windows x64 MSI를 받습니다. 일반 Intel/AMD Windows PC에서는 x64를 사용합니다.
파일 실행 → Next → 기본 설치 경로 유지 → Install → Finish 순서로 진행하고 새 창을 엽니다.
ARM Windows PC라면 이 문서의 x64 도구 경로를 그대로 사용하지 말고 해당 PC용 패키지를 확인하세요.

기본 MSI 경로를 직접 실행해 볼 수 있습니다.

```powershell
& "$env:ProgramFiles\PowerShell\7\pwsh.exe" --version
```

이것만 성공하면 새 터미널에 설치 경로가 반영되지 않은 상태일 수 있습니다.
PowerShell/VS Code를 완전히 닫고 다시 시작하세요.
</details>

<a id="check-tools"></a>
## 1-2. 저장소 폴더에서 부족한 도구 확인

Windows 탐색기로 이 저장소의 폴더를 엽니다. **`README.md`, `scripts`, `docs`가 보이는 폴더**여야 합니다.
탐색기 주소창을 클릭해서 `pwsh`를 입력하고 Enter를 누릅니다.

새 PowerShell 7 창에서:

```powershell
Test-Path .\scripts\Test-Prerequisites.ps1
```

**완료 확인:** `True`. `False`면 한 단계 안쪽/바깥쪽 폴더를 열었는지 확인합니다.

이어서:

```powershell
pwsh -NoProfile -File .\scripts\Test-Prerequisites.ps1
```

`pwsh`와 `ssh`가 PASS라면 그대로 둡니다. 아래에서 **지금 필요한 도구 중 MISSING 또는 UNSUPPORTED인 것만** 준비합니다.
`mysql`만 `MISSING`이라면 예외입니다. **지금 설치하지 말고 1-6까지 내려가 다음 장으로 진행하세요.** MySQL 클라이언트는 실제 DB 단계의 [5-6](CONNECT_AND_DATABASE.md#mysql-client)에서 준비합니다.
이 검사는 설치하거나 설정을 바꾸지 않습니다.

<a id="terraform"></a>
## 1-3. Terraform 준비 — MISSING일 때만

**실행 위치: 위에서 연 일반 사용자 PowerShell 7.**
이미 `terraform version`이 `1.9 이상, 2 미만`으로 나온다면 재설치하지 않습니다.

아래는 이 안내서 작성 시 공식 설치 페이지에 표시된 **1.16.4 Windows AMD64 ZIP**을 별도 폴더에 두는 방법입니다.
기존 1.9.8 등 이 저장소가 허용하는 버전도 보존합니다. 새 버전의 이 저장소 전체 회귀 검증은 별도로 해야 합니다.

### ① 다운로드 폴더 준비

```powershell
$tfVersion = '1.16.4'
$tfDir = Join-Path $HOME "Tools\terraform\$tfVersion"
$tfDownload = Join-Path $HOME "Downloads\terraform-$tfVersion"
if (Test-Path -LiteralPath $tfDir) { throw '설치 폴더가 이미 있습니다. 기존 terraform.exe 버전부터 확인하고 덮어쓰지 마세요.' }
New-Item -ItemType Directory -Path $tfDownload -Force | Out-Null
```

**완료 확인:** 오류가 없습니다. 이 창은 다음 블록까지 유지합니다.

### ② 공식 ZIP과 checksum 받기

```powershell
$tfBase = "https://releases.hashicorp.com/terraform/$tfVersion"
$tfZipName = "terraform_${tfVersion}_windows_amd64.zip"
Invoke-WebRequest "$tfBase/$tfZipName" -OutFile (Join-Path $tfDownload $tfZipName)
Invoke-WebRequest "$tfBase/terraform_${tfVersion}_SHA256SUMS" -OutFile (Join-Path $tfDownload 'SHA256SUMS')
```

### ③ checksum이 일치할 때만 압축 풀기

```powershell
$line = @(Get-Content (Join-Path $tfDownload 'SHA256SUMS') | Where-Object { $_ -match ('\s+' + [regex]::Escape($tfZipName) + '$') })
if ($line.Count -ne 1) { throw '공식 checksum 행을 찾지 못했습니다. 압축을 풀지 마세요.' }
$expected = ($line[0] -split '\s+')[0]
$actual = (Get-FileHash (Join-Path $tfDownload $tfZipName) -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'checksum 불일치. 설치를 중단합니다.' }
Expand-Archive -LiteralPath (Join-Path $tfDownload $tfZipName) -DestinationPath $tfDir
& (Join-Path $tfDir 'terraform.exe') version
```

**완료 확인:** `Terraform v1.16.4`. 이 비교는 HTTPS로 받은 공식 checksum과의 일치 검사이며 별도의 GPG 서명 검증이라고 부르지 않습니다.
서명 검증이 필요한 환경에서는 [HashiCorp 서명 확인 절차](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli)를 추가로 수행합니다.

### ④ 명령 검색 경로에 등록

1. Windows 시작 메뉴에서 **계정의 환경 변수 편집**을 검색해 엽니다.
2. 위쪽 **사용자 변수** 목록의 `Path`를 누릅니다. 아래쪽 시스템 Path는 건드리지 않습니다.
3. **편집 → 새로 만들기**를 누릅니다.
4. 아래 명령이 출력한 폴더를 복사해 새 줄에 붙여넣습니다. `terraform.exe` 파일명이 아닌 **폴더**입니다.

```powershell
Join-Path $HOME 'Tools\terraform\1.16.4'
```

5. 확인 → 확인으로 닫습니다. 기존 Path 행을 지우지 않습니다.
6. 터미널을 완전히 닫고 1-2처럼 저장소에서 새 PowerShell을 엽니다.

```powershell
terraform version
Get-Command terraform -All | Select-Object Source
```

**완료 확인:** 의도한 실행 경로와 버전이 나옵니다. 여러 버전이면 첫 번째 경로가 실제 선택됩니다.
기존 버전을 임의 삭제하거나 PATH 전체를 새 값으로 덮어쓰지 않습니다.

<a id="oci"></a>
## 1-4. OCI CLI 3.94.0 준비 — MISSING/다른 버전일 때만

현재 코드의 정상 빈 목록 처리는 **정확히 3.94.0**을 검증한 상태입니다.
`oci --version`이 이미 `3.94.0`이면 아래 설치를 하지 말고 1-5로 이동합니다.

이 안내서는 **기존 Python 3.12에 별도 가상환경을 만드는 수동 설치**를 사용합니다.
Oracle 공식 수동 설치 방식에 버전을 고정한 것입니다. 경로/옵션 질문이 없으므로 `Y`를 입력하지 않습니다.
기존 OCI/Python 설치를 삭제하지 않습니다.

### ① Python 실행 파일 확인

일반 사용자 PowerShell 7에서:

```powershell
$python = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    $python = (& py -3.12 -c 'import sys; print(sys.executable)')
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.12를 찾지 못했습니다. 아래 Python 준비 안내를 먼저 확인하세요.' }
}
& $python --version
```

**완료 확인:** `Python 3.12.x`. 다음 블록까지 같은 창을 유지합니다.

<details><summary>Python 3.12가 없는 경우에만</summary>

[Python Windows 배포 페이지](https://www.python.org/downloads/windows/)에서 Python 3.12 Windows installer (64-bit)를 선택합니다.
기존 Python을 지우거나 다른 프로젝트의 가상환경을 바꾸지 않습니다.
설치 프로그램의 `Install Now`로 본인 사용자 폴더에 설치하고, `py` launcher 옵션이 보이면 포함합니다.
설치가 끝나면 새 창에서 위 확인 명령을 다시 실행하세요.
최신 보안 전용 릴리스에 Windows installer가 없을 수 있습니다. 실행 가능한 3.12 설치가 이미 있으면 그대로 사용하고,
조직이 허용한 Python 배포가 따로 있으면 그 실행 파일을 `$python`으로 지정합니다.
</details>

### ② 긴 파일 경로 지원 확인

OCI CLI 도움말 파일 경로는 길 수 있습니다. 이전에 `No such file or directory`와 `Windows Long Path support`가 함께 나왔다면 특히 이 단계를 확인합니다.

```powershell
Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled
```

**완료 확인:** `1`이면 다음으로 이동합니다. `0`이거나 값이 없을 때만 아래 절차를 진행합니다.

<details><summary>LongPathsEnabled가 0/없음인 경우 — 시스템 설정 변경</summary>

시작 메뉴 → PowerShell 7 우클릭 → **관리자 권한으로 실행**을 엽니다.
본인 PC의 긴 경로 지원을 켜는 변경임을 확인하고 실행합니다. 조직 관리 PC는 관리자 정책을 우선합니다.

```powershell
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -PropertyType DWord -Value 1 -Force
```

작업을 저장하고 Windows를 재부팅합니다. 일반 사용자 PowerShell에서 다시 ① Python 확인부터 실행합니다.
관리자 창이나 `C:\Windows\System32`에 가상환경을 만들지 않습니다.
</details>

### ③ OCI 전용 가상환경 생성

```powershell
$ociDir = Join-Path $HOME 'Tools\oci-3.94.0'
if (Test-Path -LiteralPath $ociDir) { throw '동일 폴더가 이미 있습니다. 덮어쓰지 말고 아래 기존 설치 확인 안내를 보세요.' }
& $python -m venv $ociDir
if ($LASTEXITCODE -ne 0) { throw '가상환경 생성 실패. 다음 설치 명령을 실행하지 마세요.' }
```

### ④ 정확한 버전 설치

```powershell
$ociPython = Join-Path $HOME 'Tools\oci-3.94.0\Scripts\python.exe'
& $ociPython -m pip --isolated install --index-url https://pypi.org/simple 'oci-cli==3.94.0'
if ($LASTEXITCODE -ne 0) { throw 'OCI 설치 실패. 버전 확인이나 다음 단계로 넘어가지 마세요.' }
& (Join-Path $HOME 'Tools\oci-3.94.0\Scripts\oci.exe') --version
```

**완료 확인:** `3.94.0`. 이 과정은 SDK 및 의존 패키지를 함께 설치하므로 출력이 여러 줄일 수 있습니다.
가상환경을 `activate`할 필요는 없습니다. 비대화형이므로 **추가로 Y를 입력하지 않습니다.**

<details><summary>설치가 이미 있거나 설치 중 실패한 경우</summary>

먼저 해당 경로의 버전만 확인합니다.

```powershell
& (Join-Path $HOME 'Tools\oci-3.94.0\Scripts\oci.exe') --version
```

3.94.0이면 재설치하지 않고 다음 PATH 단계만 진행합니다.
이름은 같지만 실패한 가상환경이면 내용을 확인한 뒤 다른 빈 폴더에 새 환경을 만들고 그 경로를 사용하세요.
이 가이드는 기존 디렉터리 삭제 명령을 제공하지 않습니다. 특히 `System32` 또는 Python 설치 전체를 지우지 마세요.
경로 오류는 ②, HTTPS/프록시 오류는 네트워크 설정을 확인합니다. `--trusted-host`로 인증서 검증을 끄지 않습니다.
</details>

### ⑤ OCI 실행 폴더를 사용자 Path에 추가

1-3의 **사용자 Path → 편집 → 새로 만들기**에서 이번에는 아래 출력 폴더를 추가합니다.

```powershell
Join-Path $HOME 'Tools\oci-3.94.0\Scripts'
```

터미널을 완전히 닫고 저장소에서 새 PowerShell을 엽니다.

```powershell
oci --version
Get-Command oci -All | Select-Object Source
```

**완료 확인:** `3.94.0`과 위 설치 폴더가 나옵니다. 다른 버전이 먼저 실행되면 사용자 Path의 순서를 확인합니다.
시스템 Path에 있는 다른 버전을 지우지 말고, 당장 이 창에서만 다음처럼 선택할 수 있습니다.

```powershell
$env:Path = (Join-Path $HOME 'Tools\oci-3.94.0\Scripts') + ';' + $env:Path
oci --version
```

이 변경은 **현재 창에서만** 적용됩니다. 다음 새 창에서도 실행 경로를 확인해야 합니다.

## 1-5. OpenSSH는 PASS면 끝

`ssh PASS`가 나왔다면 설치하지 않습니다. **OpenSSH Server, 로컬 22번 포트 개방은 필요 없습니다.**
`ssh-agent` 준비는 3장에 나오며 SSH Client 재설치와는 다릅니다.

MISSING이면 관리자 PowerShell에서 다음 Client만 설치하고 일반 사용자 창으로 돌아옵니다.

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

**완료 확인:** 새 일반 사용자 창에서 아래 명령에 버전이 나옵니다.

```powershell
& "$env:WINDIR\System32\OpenSSH\ssh.exe" -V
```

## 1-6. 지금 필요한 네 도구가 준비됐는지 확인

저장소 폴더에서:

```powershell
pwsh -NoProfile -File .\scripts\Test-Prerequisites.ps1
```

다음 상태면 다음 장으로 갈 수 있습니다.

```text
pwsh       PASS
terraform  PASS
oci        PASS       # 3.94.0
ssh        PASS
mysql      MISSING    # 지금은 괜찮습니다
```

위처럼 **`mysql`만 MISSING이면 이 단계는 완료**입니다. 지금 필요한 네 도구(`pwsh`, `terraform`, `oci`, `ssh`)가 모두 PASS이므로 OCI 계정 준비로 이동합니다.

DB 단계에서 필요한 것은 `mysql.exe` 클라이언트입니다. Docker의 MySQL 컨테이너가 있어도
현재 DB 스크립트는 Docker를 자동 사용하지 않습니다. **MySQL 설치는 지금 하지 않고** [5-6. MySQL 클라이언트 준비](CONNECT_AND_DATABASE.md#mysql-client)에서 진행합니다. 지금 Docker나 기존 DB를 바꾸지 마세요.

**다음: [2. OCI 계정에서 값 하나씩 가져오기](ACCOUNT_SETUP.md)**

공식 근거: [Microsoft PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows),
[HashiCorp 설치](https://developer.hashicorp.com/terraform/install),
[Oracle 수동 설치](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/climanualinst.htm),
[Python Windows 긴 경로](https://docs.python.org/3.12/using/windows.html#removing-the-max-path-limitation).
