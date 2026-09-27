# OCI Always Free: AMD 서버 2대와 private MySQL

**[처음 배포하기 → GETTING_STARTED](docs/GETTING_STARTED.md)**

Oracle Cloud 계정을 만든 Windows 사용자를 위한 저장소입니다. 처음에는 위 링크만 여세요. 도구 설치, 계정 정보, 서버 생성, 접속을 각각 작은 단계로 나눴습니다. 중앙 문서 저장소나 작성자의 PC 경로는 필요하지 않습니다.

## 무엇이 만들어지나요?

| 구분 | 기본 구성 |
|---|---|
| 서버 | AMD `VM.Standard.E2.1.Micro` 2대, 각 boot 50 GB, Ubuntu/Docker |
| 네트워크 | VCN, public VM subnet, private DB subnet, NSG |
| 물리 DB | private `MySQL.Free` **1개** 50 GiB |
| 별도 DB 설정 | 명시적 승인 후 논리 DB와 전용 runtime 계정. 예: `translacat_ll`, `translacat_chat` |
| 선택 옵션 | Oracle Autonomous 0~2개, **기본 OFF**. MySQL과 다른 엔진 |

앱 배포, 앱 테이블 migration, 도메인, HTTPS 인증서, 기존 데이터 이전은 하지 않습니다. 무료 자격과 남은 한도는 **실행일 공식 자료 + 실제 계정 조회 + 사람의 확인**으로 검사합니다. 생성 가능한 물리 재고나 향후 무과금까지 보장하는 것은 아닙니다. 유료 shape, 계정 upgrade, ARM 전환, IAM 변경을 자동 실행하지 않습니다.

## 지금 어디부터 읽으면 되나요?

| 현재 상태 | 다음 문서 |
|---|---|
| `pwsh`, `terraform`, `oci` 등이 없거나 설치 도중 막혔어요 | [Windows 도구 설치](docs/TOOLS_WINDOWS.md) |
| 도구는 준비했어요. OCI에서 무엇을 복사하나요? | [계정값 하나씩 입력](docs/ACCOUNT_SETUP.md) |
| API profile을 만들었어요 | [SSH 준비와 실제 계정 조회](docs/SSH_AND_DISCOVERY.md) |
| discovery가 끝났어요 | [무료·IAM 확인과 배포 승인](docs/REVIEW_AND_DEPLOY.md) |
| Apply가 성공했어요 | [서버 접속과 DB 설정](docs/CONNECT_AND_DATABASE.md) |
| 기존 환경을 변경하거나 복구해야 해요 | [운영·복구 상세](docs/OPERATIONS.md) |

## 설정 마법사

PowerShell 7에서 **이 README와 `scripts`가 있는 저장소 루트**를 엽니다. 아래 명령 하나로 현재 입력 상태를 확인할 수 있습니다. 설치나 OCI 조회는 하지 않습니다.

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Status
```

값을 입력할 때는 [계정 안내](docs/ACCOUNT_SETUP.md)를 따라 필요한 단계만 실행합니다. 예를 들어 Home Region 하나를 입력할 때:

```powershell
pwsh -NoProfile -File .\scripts\Setup.ps1 -Environment dev -Step Region
```

마법사는 값의 출처와 저장 위치를 보여줍니다. `SAVE`를 입력해야 저장하며 `Q`는 취소입니다. 기존 다른 항목은 보존하고, 변경되는 기존 파일은 `.local/dev/setup-backups/`에 백업합니다. 실제 입력을 바꾸면 기존 무료/IAM 확인은 미확인으로 되돌립니다. `Status`는 파일·ACL도 변경하지 않습니다.

마법사는 `.local/<환경>/`의 세 설정 파일만 다룹니다. API 키 등록, `.oci/config`, 설치/PATH, IAM, 서버/DB, State, Plan 승인, SQL은 자동 변경하지 않습니다. 폴더 권한 보호는 **저장할 때만** 기존 프로젝트의 보호 함수를 사용합니다. 조회 결과가 없는 AD/image/limit는 만들어 넣지 않습니다.

## 안전한 실행 순서

**도구 → 계정값 → SSH → discovery → 무료/IAM 확인 → Preflight → Plan 검토 → 승인한 Apply → 접속 검증 → 별도 승인한 DB bootstrap → 두 번째 Plan**

이 순서를 하나의 코드 블록으로 한꺼번에 실행하지 마세요. 각 문서의 정상 결과를 확인한 뒤 다음 명령을 실행합니다. Apply의 `APPLY dev <SHA256>` 승인과 IAM·DB·삭제 승인은 서로 다릅니다. 이 README를 읽거나 설정을 저장한 것은 배포 승인이 아닙니다.

## 로컬 테스트

온보딩만 확인할 때는 다음 두 테스트를 **하나씩** 실행합니다. 임시 fixture만 사용하며 OCI 계정에 접속하지 않습니다. 결과는 `.local/` 아래에 남습니다.

```powershell
pwsh -NoProfile -File .\tests\Test-Onboarding.ps1
```

```powershell
pwsh -NoProfile -File .\tests\Test-PortableDocs.ps1
```

기존 전체 검증은 다음과 같습니다. Terraform과 provider 다운로드 환경이 필요합니다. provider 8.5.0과 기존 lock file을 유지합니다.

```powershell
pwsh -NoProfile -File .\scripts\Validate.ps1 -EvidenceDirectory .\.local\validation
```

오프라인 테스트는 실제 계정 자격, live plan/apply, IAM, 실제 SSH/TLS/DB 성공을 대신하지 않습니다. 테스트를 추가했다는 사실과 실제 실행해 PASS한 결과를 구분하세요.

## 설정·문서 보존

`.local`, `.terraform`, State/plan, 실제 tfvars, 키·wallet·비밀번호는 Git이나 공유 ZIP에 넣지 않습니다. `sensitive`는 State 암호화가 아닙니다. 기존 데이터·State·설정·미커밋 변경을 지우지 마세요.

문서 정본을 별도 `CatPjt-TranslaCat-docs` 저장소에서 관리하는 경우, **이 패치의 `docs/` 9개 파일 전체를 그 정본에도 먼저 반영**하세요. 이 패치는 업로드된 Terraform 저장소만 수정합니다. 수정 전 중앙 정본을 동기화해서 새 가이드를 되돌리지 마세요.

`Sync-Docs.ps1`은 9개 문서가 모두 있는지 확인한 뒤에만 복사합니다. 유지보수자만 자신의 정본 폴더를 지정해 실행합니다. 일반 사용자는 실행하지 않아도 됩니다.

```powershell
pwsh -NoProfile -File .\scripts\Sync-Docs.ps1 -SourceDirectory '정본의-절대경로' -Check
```

[공식 근거](docs/SOURCES.md) · [기존 12단계 원문 보관본](docs/PROCEDURE_REFERENCE.md)
