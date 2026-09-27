# 4. 무료·IAM 확인 후 Plan 검토

[SSH와 discovery](SSH_AND_DISCOVERY.md) → **검토와 배포** → [서버·DB 접속](CONNECT_AND_DATABASE.md)

**이 페이지를 시작할 조건:** discovery 성공, 마법사 Placement/Limits 저장 완료.
이제까지 마법사는 입력을 도왔지만 **무료 확인 체크를 자동으로 true로 바꾸지 않았습니다.**

이 장에는 사람이 확인해야 하는 두 항목이 남습니다. **무료 표시와 실제 권한 정책**입니다.
두 확인이 끝나기 전에는 Apply를 실행하지 않습니다.

## 4-1. 검토 기록 파일 하나 열기

**실행 위치: 저장소 폴더의 일반 사용자 PowerShell 7.**

```powershell
notepad .\.local\dev\console-review.json
```

이 파일만 편집합니다. `iam-review.json`은 조회 결과이므로 직접 고치지 않습니다.
`config.json`의 후보를 바꾸고 싶다면 앞 장 마법사로 돌아갑니다.
기존 파일 전체를 예제로 덮어쓰지 않습니다. JSON의 `true`/`false`에는 따옴표가 없습니다.

## 4-2. 기존 자원 목록 확인

별도 창/편집기로 조회 결과를 엽니다.

```powershell
notepad .\.local\dev\discovery.json
```

`resources` 목록을 확인합니다. 새 계정이라는 이유로 빈 목록이라고 가정하지 않습니다.
조회된 서버/volume/backup/DB가 있으면 콘솔의 같은 리전·compartment에서 대조합니다.
분리된 boot/block volume과 남은 backup도 기존 사용량입니다.

확인 불가능한 리전/compartment가 있거나 조회 권한이 부족하면 **false를 그대로 두고 중단**합니다.
자원을 삭제하거나 다른 compartment로 옮겨 무료 검사를 통과시키지 않습니다.

## 4-3. 무료 표시를 확인하고 해당 항목만 기록

아래를 **한 행씩** 처리합니다. 화면에서 확인한 뒤에만 `console-review.json`의 같은 이름을 `true`로 바꿉니다.
화면이 다르거나 조건이 맞지 않으면 다음 행을 자동으로 채우지 않습니다.

| 이번에 확인할 것 | 어디서 무엇을 볼지 | 확인 후 바꿀 필드 |
|---|---|---|
| 실행일 공식 무료 조건 | [공식 근거](SOURCES.md)의 원문. 템플릿의 상한과 실행일 조건을 대조 | `official_policy_confirmed` |
| 문서/계정 조건에 모순이 없는지 | 공식 내용과 콘솔이 다르면 원인을 확인. 미해소면 false | `policy_conflicts_resolved` |
| 모든 대상 조회 범위 | discovery의 구독 리전/compartment를 읽을 권한이 있는지 확인 | `tenancy_wide_inspect_confirmed` |
| AMD 무료 서버 | Compute → Instances → Create instance. 선택 OS와 `VM.Standard.E2.1.Micro`의 Always Free 표시 확인. **Create 누르지 않음** | `always_free_compute_confirmed` |
| 무료 MySQL | MySQL HeatWave → DB Systems → Create DB System. Home Region·선택 AD·`MySQL.Free`와 무료 표시 확인. **Create 누르지 않음** | `always_free_mysql_confirmed` |
| MySQL 백업 정책 | 공식 MySQL 무료 설명과 실제 설정. 무료 자동 백업 1일/잔여 백업 및 50 GB 범위 확인 | `mysql_backup_policy_confirmed` |
| 한도와 quota | Limits, Quotas and Usage에서 서비스/리전/AD별 usage/available 확인. 큰 quota 자체는 무료 근거가 아님 | `limits_quotas_reviewed` |

Autonomous가 기본 OFF라면 `always_free_autonomous_confirmed`는 **false로 둡니다**.
별도로 켠 경우에만 무료·20 GB·mTLS/접속 ACL을 확인한 뒤 true로 기록합니다.

완료한 사실을 `notes`에 짧게 기록합니다. 예를 들어 확인한 화면 이름과 미해소 사항을 적고,
실제 확인하지 않은 화면을 확인했다고 기록하지 않습니다. 개인키/비밀번호는 넣지 않습니다.

`reviewed_on`에는 **실제로 확인한 오늘 날짜 `YYYY-MM-DD`**를 넣습니다.
`tenancy_ocid`, `region`, `account_status`는 앞에서 저장한 실제 값이 맞는지 읽어 확인합니다.
날짜만 새로 바꿔 예전 검토를 재사용하지 않습니다. Ctrl+S로 저장합니다.

**완료 확인:** 적용되는 무료 확인 항목이 실제 근거를 갖고 true이며, 미확인 항목은 남아 있지 않습니다.
이 기록은 최종 청구/물리 capacity를 보장하지 않습니다.

## 4-4. MySQL NSG 권한 검토 자료 열기

사용자 본인의 권한과 **MySQL DB 서비스 자체가 네트워크를 사용할 권한**은 다릅니다.
관리자 계정이라는 이유로 두 번째 권한이 있다고 가정하지 않습니다.

```powershell
notepad .\.local\dev\iam-review.json
notepad .\examples\mysql-nsg-policy.txt.example
```

첫 파일은 실제 조회 결과, 두 번째는 필요한 권한의 제한된 예제입니다.
정책 예제의 토큰을 바꾸지 않은 채 OCI에 붙여넣지 않습니다.

## 4-5. 사용자 그룹 OCID 하나 확인

1. OCI **Identity & Security → Domains**를 엽니다.
2. API 키를 등록한 사용자가 속한 **Domain**을 엽니다.
3. **Groups**에서 그 사용자가 실제로 포함된 그룹을 엽니다.
4. **Members**에서 사용자를 확인합니다.
5. 그룹 상세의 **OCID → Copy**를 누릅니다.

`console-review.json`의 `mysql_nsg_iam.deployer_group_ocid`에 이 값 하나를 넣습니다.
그룹 이름이 아니라 `ocid1.group...` 값입니다.

기존 구형 설정에 `mysql_nsg_iam` 자체가 없으면 [예제](../examples/console-review.json.example)의
**그 object만** 추가합니다. 기존 review 전체를 덮어쓰지 않습니다.

## 4-6. 정책을 확인하고, 필요한 경우에만 별도 승인 후 생성

1. OCI **Identity & Security → Policies**를 엽니다.
2. 왼쪽 compartment를 **root tenancy**로 선택합니다.
3. `iam-review.json`에서 제시된 root/상위/대상 정책을 찾아 statement와 조건을 확인합니다.
4. [Oracle 필수 정책](https://docs.oracle.com/en-us/iaas/mysql-database/doc/mandatory-policies-permissions.html)과
   로컬 `mysql-nsg-policy.txt.example`의 요구 사항을 대조합니다.

기존 정책이 충분하면 **정책을 새로 만들지 않습니다**.
필요한 권한이 없으면 예제의 그룹 ID, DB/NSG/subnet compartment ID를 실제 값으로 치환해
**추가할 statement와 범위부터 검토**합니다. 사용자에게 필요한 조회/생성 권한 전체와도 대조해야 합니다.
이 예제 하나가 모든 API 사용자 권한을 부여하는 정책이라고 가정하지 않습니다.

그 변경을 별도로 승인한 후에만 **Create Policy → Show manual editor**에서 승인한 statement를 입력합니다.
이 템플릿은 DB·NSG·subnet을 같은 전용 compartment에 두므로 이 셋의 범위는
`config.json`의 `compartment_ocid`와 같습니다. tenancy 전역 관리자 권한으로 대체하지 않습니다.

정책을 만들거나 바꿨다면 전파를 기다린 뒤 **읽기 discovery를 다시 실행**합니다.
정책이 ACTIVE인 것과 실제 생성 권한이 유효한지는 다르며, 최종 생성 성공을 여기서 보장하지 않습니다.

## 4-7. IAM 검토 결과만 기록

다시 `console-review.json`의 `mysql_nsg_iam` 부분만 편집합니다.

| 필드 | 넣을 값/확인 |
|---|---|
| `reviewed_on` | 오늘 실제 확인한 날짜 |
| `tenancy_ocid`, `region` | 이 환경의 실제 tenancy와 Home Region |
| `db_compartment_ocid`, `nsg_compartment_ocid`, `subnet_compartment_ocid` | 세 곳 모두 이번 전용 compartment OCID |
| `deployer_group_ocid` | 4-5에서 확인한 그룹 |
| `policy_ocids` | 검토한 실제 ACTIVE 정책 OCID들의 JSON 배열 |
| `policy_disposition` | 기존 충분 정책이면 `EXISTING_SUFFICIENT`; 별도 승인 후 신규/수정이면 `CREATED_WITH_APPROVAL` |
| `api_user_group_membership_confirmed` | 실제 그룹 membership을 확인한 경우에만 true |
| `user_permissions_confirmed` | API 사용자의 필요한 권한을 확인한 경우에만 true |
| `db_principal_permissions_confirmed` | MySQL DB resource principal의 NSG/VNIC 권한을 확인한 경우에만 true |
| `conditions_and_scope_confirmed` | 그룹·compartment·principal 조건과 상속 범위를 대조한 경우에만 true |
| `conflicts_resolved`, `unresolved_items` | 미해소 문제가 정말 없을 때만 true / `[]`. 목록 삭제로 문제를 해결한 것으로 만들지 않음 |
| `separately_approved_change_confirmed` | 신규/수정 정책을 별도 승인하여 적용한 경우만 true. 기존 충분 정책이면 false |

예를 들어 배열은 `"policy_ocids": ["실제_정책_OCID"]` 형식이며 placeholder를 그대로 입력하지 않습니다.
Ctrl+S로 저장합니다. 자세한 조건 설명은 [OPERATIONS](OPERATIONS.md)를 참고합니다.

**완료 확인:** 필요한 IAM 확인에 실제 근거가 있고, `UNREVIEWED` 또는 미해소 항목이 남아 있지 않습니다.
이 구간의 권한 해석이 불명확하면 Apply를 진행하지 말고 계정 관리자/Oracle 지원과 확인합니다.

## 4-8. 실제 Preflight 실행

```powershell
pwsh -NoProfile -File .\scripts\Preflight.ps1 -Environment dev
```

**완료 확인:** `PREFLIGHT PASS`.
`REVIEW_REQUIRED`, 무료 조건 미확인, 한도 부족, 이미지/AD 오류면 다음 Plan으로 이동하지 않습니다.
마법사로 값을 바꿨다면 review가 미확인으로 바뀌므로 관련 확인을 다시 수행합니다.

## 4-9. 생성 계획만 만들기

```powershell
pwsh -NoProfile -File .\scripts\Plan.ps1 -Environment dev
```

MySQL 관리자 암호는 보안 입력창에서 입력하고 본인의 암호 관리자에 보관합니다.
재plan에서는 이미 정한 현재 암호를 사용합니다. 암호를 명령 인자나 JSON에 넣지 않습니다.

**완료 확인:** `LIVE_PLAN_VERIFIED_AWAITING_APPLY_APPROVAL`.
이 단계는 OCI 서버/DB를 아직 만들지 않습니다. Plan 파일에는 비밀이 들어갈 수 있으므로 공유하지 않습니다.

## 4-10. 화면의 계획을 읽고 멈추기

대상 tenancy/Home Region/compartment가 본인 것이 맞는지 확인합니다.
새 기본 환경에서는 **AMD Micro 2대, 각 boot 50 GB, Private MySQL.Free 1개와 필요한 네트워크**가 예정됩니다.
Autonomous는 0개, 삭제/교체는 없어야 합니다.

유료 shape/이미지, HA/PITR/자동확장, 예상 밖 자원, 삭제/교체가 보이면 승인하지 않습니다.
무료 잔여량에는 기존 자원이 반영되어야 합니다. 잘 모르겠는 항목은 여기서 확인합니다.

**여기까지가 안전하게 멈출 수 있는 ‘Plan 검토 완료’ 지점입니다.**
바로 배포하지 않아도 됩니다. 계획이 오래되거나 설정/State가 바뀌면 새 Preflight/Plan이 필요합니다.

## 4-11. 검토한 Plan을 승인했을 때만 적용

```powershell
pwsh -NoProfile -File .\scripts\Apply.ps1 -Environment dev
```

스크립트가 표시하는 **`APPLY dev <해당 SHA256>`** 문구를 정확히 입력해야 실행됩니다.
가이드에 있는 임의 hash를 입력하지 않습니다.

실패하거나 취소되면 자동으로 재실행하지 않습니다. 현재 OCI 자원과 State부터 확인합니다.
성공해도 SSH/cloud-init/DB 접속 검증은 아직 남아 있습니다.

**다음: [5. 서버 접속 → DB 연결](CONNECT_AND_DATABASE.md)**
