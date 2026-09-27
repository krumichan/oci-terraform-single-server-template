# 처음 시작하기 — 한 번에 한 단계씩

이 안내서는 **Windows에서 OCI 계정만 준비한 사람**을 위한 순서표입니다.
기존 설정이 있으면 지우지 않습니다. 이미 끝낸 설치도 다시 하지 않습니다.

**지금 필요한 것은 서버를 만드는 명령이 아니라, 내 PC와 계정 정보를 준비하는 일입니다.**
아래 순서대로 진행하고, 각 페이지의 **완료 확인**을 통과했을 때만 다음 페이지로 이동하세요.

## 어디서 시작하나요?

| 내 상태 | 시작할 페이지 |
|---|---|
| `pwsh` 명령부터 안 된다 | [1. PC 도구 준비](TOOLS_WINDOWS.md#powershell) |
| PowerShell/SSH는 PASS, Terraform/OCI가 MISSING | [1. 누락된 도구만 설치](TOOLS_WINDOWS.md#check-tools) |
| `pwsh`/`terraform`/`oci`/`ssh`는 PASS, `mysql`만 MISSING | **정상입니다. MySQL은 지금 설치하지 말고** [2. OCI 계정 준비](ACCOUNT_SETUP.md)로 이동 |
| 도구가 준비됐다. Oracle에서 값을 어디서 찾는지 모른다 | [2. OCI 계정에서 값 하나씩 가져오기](ACCOUNT_SETUP.md) |
| API 인증까지 됐다 | [3. SSH 준비와 실제 계정 조회](SSH_AND_DISCOVERY.md) |
| `DISCOVERED`가 나왔다 | [3. 조회 후보를 번호로 선택](SSH_AND_DISCOVERY.md#placement) |
| 입력과 후보 선택이 끝났다 | [4. 무료·IAM 확인 후 Plan 검토](REVIEW_AND_DEPLOY.md) |
| 승인한 Plan으로 서버를 만들었다 | [5. 서버 접속 → DB 연결](CONNECT_AND_DATABASE.md) |

> **`mysql MISSING`이어도 지금은 정상입니다.**
> 처음 배포를 시작할 때 필요한 도구는 `pwsh`, `terraform`, `oci`, `ssh` 네 가지입니다. 이 네 개가 모두 `PASS`이면 OCI 계정 준비로 진행하세요.
> `mysql.exe`는 서버와 Private MySQL DB System을 만든 뒤 실제 DB 접속·TLS·Bootstrap을 검증할 때만 필요합니다. 설치 시점은 [5-6. MySQL 클라이언트 준비](CONNECT_AND_DATABASE.md#mysql-client)에서 다시 안내합니다.
> Docker가 설치되어 있어도 현재 스크립트가 사용할 로컬 `mysql.exe`가 생기는 것은 아니지만, **지금 Docker나 MySQL을 추가 설치할 필요는 없습니다.**

## 최종적으로 무엇을 만드나요?

기본 입력을 바꾸지 않으면 **AMD Micro 서버 2대와 Private MySQL DB System 1개**를 요청합니다.
서버에는 Ubuntu와 Docker를 준비하고, 서버용/DB용 네트워크를 나눕니다.
DB 내부의 `translacat_ll`, `translacat_chat`과 전용 계정은 **나중에 별도 승인**을 받아 만듭니다.

```text
서버 1 ─┐
        ├── 비공개 MySQL DB System 1개
서버 2 ─┘      ├── translacat_ll
               └── translacat_chat
```

서버는 각각 50 GB boot volume, MySQL은 50 GiB로 설정되어 있습니다.
Oracle Autonomous DB는 별도 옵션이며 **기본 OFF**입니다. MySQL 두 대를 만드는 구성이 아닙니다.
**앱 배포, 앱 테이블, 데이터 이전, 도메인·HTTPS 인증서는 이 작업에 포함하지 않습니다.**

무료 가능 여부는 실제 계정·기존 사용량·실행일 공식 조건을 확인한 뒤 판단합니다.
Trial 잔액이 있거나 지금 청구가 0이라는 이유만으로 무료라고 판정하지 않습니다.

## 파일을 직접 찾아 고치는 대신 마법사에 입력합니다

PowerShell 7이 준비되면, 저장소 폴더에서 다음처럼 **필요한 항목 하나만** 실행합니다.
저장소 폴더는 `README.md`와 `scripts` 폴더가 함께 있는 위치입니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Region
```

화면에는 해당 값을 어디서 찾는지와 어디에 저장하는지가 나옵니다.

```text
=== Home Region 코드 하나 입력 ===
1. OCI 콘솔 위쪽 Region(리전 이름)을 누릅니다.
2. Manage Regions(리전 관리)를 누릅니다.
3. Home 표시가 있는 행의 Region Identifier를 복사합니다.
현재 값: REPLACE_WITH_HOME_REGION
입력: [본인 계정에서 복사한 값]
저장하려면 SAVE 입력: SAVE
```

**`SAVE`를 입력하기 전에는 저장하지 않습니다.** `Q`로 취소할 수 있습니다.
같은 값을 다시 저장하면 파일은 그대로입니다. 변경 전 파일은 `.local/dev/setup-backups/`에 보관합니다.
마법사는 OCI 호출, 설치, IAM 변경, 키 생성, DB 작업, Terraform State 변경을 하지 않습니다.
입력이 바뀌면 예전 무료·IAM 확인은 미확인으로 되돌려 잘못 재사용하지 않게 합니다.

입력 상태만 보고 싶을 때:

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Status
```

전체 메뉴를 열고 싶은 때:

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev
```

계정 식별자·SSH 공개키 경로·AD/이미지·한도·논리 DB 이름을 도와주는 **로컬 입력 도구**입니다.
API 개인키 등록, 실제 무료 표시, IAM 정책의 의미, 인증서 신뢰는 사용자가 확인해야 합니다.
마법사 입력 완료를 무료 검증 PASS로 취급하지 않습니다.

## 안전한 진행 규칙

명령 블록은 **하나씩** 실행합니다. 중간 오류가 있으면 뒤의 블록은 실행하지 않습니다.
일반 사용자 창이 기본입니다. 관리자 창이 필요한 경우 해당 단계에서만 따로 표시합니다.
설치 질문의 `Y`는 언제나 “예”가 아닙니다. 경로 질문에는 경로를 입력하거나 Enter를 눌러야 합니다.
이 안내서의 OCI 설치는 경로를 명령에 지정하여 그런 질문이 나오지 않게 합니다.

`Apply`를 승인하기 전에는 Terraform이 서버나 DB를 만들지 않습니다.
다만 API 키 등록·compartment 생성·IAM 정책 변경은 각각 계정 변경이므로 해당 화면에서 확인하고 실행합니다.
비밀번호, 개인키 본문, State/Plan 파일은 Git이나 채팅에 올리지 않습니다.

**이제 [1. PC 도구 준비](TOOLS_WINDOWS.md)로 이동하세요.**
이미 도구가 준비됐다면 [2. OCI 계정 준비](ACCOUNT_SETUP.md)부터 시작하세요.

---

설정 원리·장애 대응·State·백업·삭제는 [운영 매뉴얼](OPERATIONS.md), 근거 문서는 [SOURCES](SOURCES.md)에 있습니다.
고급 내용을 읽지 않아도 기본 절차는 연결되지만, IAM·SSH·TLS의 **실제 확인 단계는 생략하지 않습니다.**
기존 12단계 문서는 참고용 [상세 절차 원본](PROCEDURE_REFERENCE.md)으로 보존했습니다. 새 사용자는 위 순서를 사용하세요.
