# OCI Always Free 구현 근거

공개 문서 확인일: **2026-09-27**. 이 기록은 공식 문서를 직접 조회한 결과이며, 특정 OCI 계정의 자격·재고·잔여량·청구를 확인한 기록이 아니다. 실행일에는 아래 정책과 대상 계정을 다시 확인한다. 최초 인계 문서 `handoff/SOURCES.md`는 원본 그대로 보존한다.

## 무료 자원과 제약

| ID | 공식 출처 | 이번 구현에 사용하는 근거 |
|---|---|---|
| F1 | [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) | home region의 AMD `VM.Standard.E2.1.Micro` 최대 2대. Compute boot/block 합계 200 GB, 두 종류의 volume backup 합계 5개. VM당 RAM 1 GB. 기존·분리된 boot volume도 합산한다. |
| F2 | [Features of MySQL HeatWave Service](https://docs.oracle.com/en-us/iaas/mysql-database/doc/features-mysql-heatwave-service.html) | Commercial realm의 tenancy당 Always Free MySQL 1개, home region, `MySQL.Free`, 데이터/로그 50 GiB. 최신 MySQL 버전으로 생성되고 maintenance 때 최신 버전으로 갱신된다. HA·read replica·PITR·수동 backup은 지원되지 않는다. |
| F3 | [Creating an Always Free DB System](https://docs.oracle.com/en-us/iaas/mysql-database/doc/creating-always-free-db-system.html) | 무료 shape의 limit가 있는 AD를 선택한다. 자동 backup enabled, 보존 1일, backup window는 Oracle 결정, soft delete disabled. HeatWave cluster 없이 DB System만 생성할 수 있다. |
| F4 | [Supported Shapes](https://docs.oracle.com/en-us/iaas/mysql-database/doc/supported-shapes.html) | `MySQL.Free`는 2 ECPU/8 GiB, `HeatWave.Free`는 16 GiB/1노드. 목록 제공과 생성 가능한 물리 재고는 구별한다. |
| F5 | [Always Free Autonomous AI Database](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-always-free.html) | 최대 2개, 각각 20 GB, home region만 허용. private endpoint 불가. 수동·자동 scaling 불가, restore 및 장기·수동 backup 제한. 7일 비활성 시 자동 정지, 누적 90일 정지·비활성 시 회수될 수 있다. |
| F6 | [Overview of Backups](https://docs.oracle.com/en-us/iaas/mysql-database/doc/overview-backups.html) | 무료 MySQL 자동 backup은 1일, 최종 backup은 7일. 수동 backup/PITR/soft delete는 지원되지 않는다. 삭제 후 남는 backup도 따로 확인한다. |
| F7 | [Restoring From a Backup](https://docs.oracle.com/en-us/iaas/mysql-database/doc/restoring-from-backup.html) | MySQL 복원은 새 DB System을 만든다. 유료 DB backup을 Always Free DB로 복원할 수 없다. 복원은 기존 무료 DB 수·용량 및 데이터 영향까지 별도 검토해야 한다. |
| F8 | [Block Volume Performance](https://docs.oracle.com/en-us/iaas/Content/Block/Concepts/blockvolumeperformance.htm), [Launching Your First Linux Instance](https://docs.oracle.com/en-us/iaas/Content/Compute/tutorials/first-linux-instance/overview.htm) | Balanced는 10 VPU/GB이며 boot volume 기본 성능이다. 무료 튜토리얼은 50 GB/Balanced, backup policy 미선택, cross-region replication OFF를 사용한다. 높은 성능·자동 성능 증가를 무료라고 추정하지 않는다. |
| F9 | [OCI Free Tier FAQ](https://www.oracle.com/cloud/free/faq/) | Trial 크레딧과 Always Free는 다른 개념이다. 크레딧으로 현재 청구가 0이라고 무료 조건이 충족되는 것은 아니다. |
| F10 | [Budgets Overview](https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/budgetsoverview.htm) | Budget은 알림을 위한 soft limit이며 지출을 차단하는 hard cap이 아니다. |

F1은 무료 MySQL 데이터/로그 외에 backup 50 GB도 별도로 안내한다. 이것을 Compute의 200 GB 풀과 합치지 않는다. 문서의 GB 표기와 API의 GiB 표기는 구별하여 원본 값을 기록한다.

구현은 기존 MySQL 무료 backup 사용량에 신규 DB당 50 GiB의 backup 여유를 더해 검사한다. 50 GiB를 넘으면 차단하는 보수적 배포 정책이며, 실제 생성 직후 그 공간이 모두 사용된다는 공식 주장과 구별한다.

## 대상 계정 읽기 전용 조회

아래 명령은 구현 근거를 보여주는 형식이다. 실제 실행에서는 전용 profile과 검증된 region을 명시하며, 결과 원문은 계정 식별 정보가 있는 비공개 로컬 파일로 취급한다.

| 항목 | 공식 출처 | 명령/검사할 필드 |
|---|---|---|
| home region | [Region subscriptions](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/iam/region-subscription/list.html), [RegionSubscription](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/identity/models/oci.identity.models.RegionSubscription.html) | `oci iam region-subscription list --tenancy-id ... --all`; `region-name`, `is-home-region`, `status` |
| 전체 compartment | [List compartments](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/iam/compartment/list.html) | root에서 `--compartment-id-in-subtree true --access-level ANY --all`. root도 별도 포함. ANY는 리소스 조회 권한을 증명하지 않으므로 각 compartment의 조회 실패 시 중단한다. |
| MySQL 목록 | [DB system list](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/mysql/db-system/list.html) | `oci mysql db-system list --compartment-id ... --all`에서 `id`, `shape-name`, `lifecycle-state`를 수집하고 개별 `db-system get` 응답의 storage·HA·`backup-policy`를 확인한다. 무료 분류에 존재하지 않는 `is-free-tier`를 사용하지 않는다. |
| MySQL shape | [MySQL shape list](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/mysql/shape/list.html), [MysqlaasClient](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/mysql/client/oci.mysql.MysqlaasClient.html) | `oci mysql shape list --compartment-id ... --availability-domain ... --all --is-supported-for DBSYSTEM`; `data`는 ShapeSummary 배열이며 `name`이 `MySQL.Free`인 항목이 있어야 한다. |
| MySQL version | [MysqlaasClient](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/mysql/client/oci.mysql.MysqlaasClient.html), [VersionSummary](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/mysql/models/oci.mysql.models.VersionSummary.html) | `oci mysql version list --compartment-id ... --all`; `data`는 VersionSummary 배열이다. 각 항목에 `version-family`와 `versions` 배열이 있다. AD 인자는 없으며 목록이 무료 생성 버전 선택권을 뜻하지 않는다. |
| 공식 Compute image 후보 | [OCI CLI 시작 안내](https://docs.oracle.com/en-us/iaas/Content/GSG/Tasks/gettingstartedwiththeCLI.htm), [Image 모델](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/core/models/oci.core.models.Image.html) | 공식 OCI 예제의 platform image는 `compartment-id: null`이다. API 모델 설명 자체는 null 의미를 보장하지 않으므로 빈 compartment만으로 비용을 확정하지 않고 공식 OS·shape 호환성·크기·계정 콘솔 표시도 대조한다. |
| MySQL backup | [Backup list](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/mysql/backup/list.html), [BackupSummary](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/mysql/models/oci.mysql.models.BackupSummary.html) | `oci mysql backup list --compartment-id ... --all`; `backup-size-in-gbs`는 backup GiB, `data-storage-size-in-gbs`는 원본 volume 크기. `shape-name`, `db-system-id`, `lifecycle-state`도 보존한다. |
| limit 정의 | [Limit definition list](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/limits/definition/list.html), [LimitDefinitionSummary](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/limits/models/oci.limits.models.LimitDefinitionSummary.html) | `name`, `service-name`, `scope-type`, `is-resource-availability-supported`. scope가 AD이면 AD를 지정하고 REGION/GLOBAL이면 임의 AD를 넣지 않는다. |
| limit 잔여량 | [Resource availability get](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/limits/resource-availability/get.html), [ResourceAvailability](https://docs.oracle.com/en-us/iaas/tools/python/latest/api/limits/models/oci.limits.models.ResourceAvailability.html) | `used`, `available`, `fractional-usage`, `fractional-availability`. 미지원이면 404·빈 JSON·빈 값이 가능하다. 이를 0 또는 무료 PASS로 바꾸지 않는다. |

공식 문서에서 확인한 limit 이름은 다음과 같다. 실제 계정에서 definition과 scope를 다시 대조한다.

| 역할 | family/service 후보 | 이름 | scope | 근거 |
|---|---|---|---|---|
| AMD | compute | `standard-e2-micro-core-count` | AD | [Compute Quotas](https://docs.oracle.com/en-us/iaas/Content/Quotas/Concepts/resourcequotas_topic-Compute_Quotas.htm) |
| boot/block | block-storage | `total-storage-gb` | AD | [Block Volume Quotas](https://docs.oracle.com/en-us/iaas/Content/Quotas/Concepts/resourcequotas_topic-Block_Volume_Quotas.htm) |
| volume backup | block-storage | `backup-count` | REGION | [Block Volume Quotas](https://docs.oracle.com/en-us/iaas/Content/Quotas/Concepts/resourcequotas_topic-Block_Volume_Quotas.htm) |
| Autonomous | database | `adb-free-count` | REGION | [Autonomous compartment quotas](https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-database-compartment-quotas.html) |
| MySQL.Free | 계정 discovery로 확인 | 공개 문서만으로 확정하지 않음 | 무료 limit가 있는 AD | F3 |

quota는 생성 가능한 총량이지 그 전체가 무료라는 뜻이 아니다. MySQL.Free limit 이름을 추측해 유료 MySQL limit와 바꾸지 않는다. 구현은 계정 definition의 이름과 설명에서 MySQL.Free DB System 수량 한도로 알아볼 수 있는 항목만 허용한다. HeatWave cluster·storage·backup 한도 또는 의미가 모호한 definition은 중단한다. 목록·권한·pagination·scope·숫자 중 하나라도 불명확하면 검사에 실패한 상태로 유지한다.

## Provider·인증·데이터 안전

| 공식 출처 | 적용 원칙 |
|---|---|
| [OCI MySQL Terraform resource](https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/mysql_mysql_db_system.html) | `shape_name`, `data_storage`, `backup_policy`, `deletion_policy`는 잠근 provider의 schema와 교차 확인한다. latest 문서 조회만으로 8.5.0 검증을 대신하지 않는다. |
| [OCI Autonomous Terraform resource](https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/database_autonomous_database.html) | `is_free_tier = true`, scaling OFF, mTLS ON을 명시한다. Serverless는 `whitelisted_ips`를 사용한다. `is_access_control_enabled`는 Cloud@Customer 설명이므로 그대로 복사하지 않는다. |
| [API signing keys and OCIDs](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm) | API signing key와 VM SSH key를 분리한다. API profile의 region은 콘솔 선택 리전일 수 있으므로 home region과 대조한다. |
| [MySQL TLS networking troubleshooting](https://docs.oracle.com/en-us/iaas/mysql-database/doc/troubleshooting-networking.html), [MySQL encrypted connections](https://docs.oracle.com/cd/E17952_01/mysql-8.4-en/using-encrypted-connections.html) | 기본 SYSTEM 인증서는 self-signed일 수 있다. 신뢰 경로에서 인증서를 확인하며 VERIFY_CA/VERIFY_IDENTITY와 TLS 강제 계정을 사용한다. 서버에서 받은 인증서를 무검증 신뢰하거나 TLS 검증을 끄지 않는다. |
| [MySQL HeatWave unsupported features](https://docs.oracle.com/en-us/iaas/mysql-database/doc/unsupported-features.html), [Default MySQL privileges](https://docs.oracle.com/en-us/iaas/mysql-database/doc/default-mysql-privileges.html) | HeatWave는 `partial_revokes`를 기본 활성화하며 disable을 허용하지 않는다. schema의 `_`/`%`를 literal로 다루므로 database별 완전한 grant를 사용한다. 관리자 권한은 self-managed root와 다르지만 시스템 schema 읽기와 사용자별 grant 검사가 가능하며 직접 시스템 테이블을 수정하지 않는다. |
| [Terraform sensitive data](https://developer.hashicorp.com/terraform/language/manage-sensitive-data) | `sensitive`는 마스킹이다. DB 비밀번호가 State와 saved plan에 남을 수 있다. |
| [Terraform validation](https://developer.hashicorp.com/terraform/language/validate) | 비용 차단은 실패하는 validation/precondition/정책 검사로 구현한다. 경고만 남길 수 있는 check를 유일한 차단 수단으로 쓰지 않는다. |

## 실행일 재확인과 문서 불일치

Preflight의 문서 확인은 고정된 숫자를 영구 보증하는 절차가 아니다. 실행일에 공식 URL에 접근하고, 핵심 정책 문구와 계정 콘솔·API 정보를 함께 대조한다. HTML 오류 페이지, 접근 거절, 핵심 문구 소실, 변경된 상한, 다른 realm/region 또는 읽을 수 없는 계정 사용량은 자동 통과 사유가 아니다. 사용자 확인 기록에는 확인일, tenancy, home region, 계정 상태, 무료 표시, 선택 이미지·shape, 확인 근거를 남긴다. 단순히 과거 확인일을 오늘로 바꾸지 않는다.

현재 문서에서 관찰한 차이:

- F1 안에서도 boot minimum은 47 GB와 50 GB로 다르게 적혀 있다. 템플릿은 50 GB를 명시하고 실제 이미지의 최소 크기를 추가 확인한다.
- F1의 ADB 동시 세션 요약은 20, F5 상세는 30이다. 세션 수를 비용 정책이나 성능 보장값으로 사용하지 않는다.
- ARM 관련 오래된/마케팅 안내와 F1의 수치가 다르다. 이 템플릿은 AMD만 다루므로 ARM fallback의 근거로 사용하지 않는다.
- 무료 MySQL의 최신 강제 버전은 기존 MySQL 8.4 애플리케이션과 동일하다는 뜻이 아니다. 실제 배포 버전과 JDBC/EF Core/Exposed 등 드라이버·마이그레이션 호환성을 별도로 검증한다.

호스트 재고는 shape 목록과 quota로 보장되지 않는다. capacity 부족 시 원인을 기록하고 중단하며, 유료 shape·계정 upgrade·ARM 전환을 자동 실행하지 않는다.

## 후속 준비·설치·IAM·SSH 근거 (2026-09-27 재조회)

| 공식 출처 | 확인한 내용과 구현 연결 |
|---|---|
| [PowerShell Windows 설치](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows) | Windows PowerShell 5.1과 PowerShell 7은 함께 설치 가능하다. 공식 WinGet/MSI/ZIP 중 사용자 환경에 맞게 선택하고 새 창에서 PATH를 확인한다. |
| [Terraform 설치](https://developer.hashicorp.com/terraform/install) | Windows 바이너리와 checksum/서명 검증 경로를 제공한다. 템플릿 버전 제약과 provider lock은 별도로 검증한다. |
| [OCI CLI Windows Quickstart](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) | Windows MSI/PowerShell 설치 경로 및 oci --version. MSI의 기존 설치 덮어쓰기 가능성을 고려하여 설치 전 실제 경로를 확인한다. |
| [MySQL Windows 설치](https://dev.mysql.com/doc/refman/8.4/en/windows-installation.html), [ZIP 수동 설치](https://dev.mysql.com/doc/refman/8.4/en/windows-install-archive.html) | Oracle mysql.exe client와 DLL을 보존하고 필요한 runtime을 설치한다. 이 템플릿 접속을 위해 로컬 MySQL server를 초기화할 필요는 없다. mysqlsh와 mysql.exe는 구별한다. |
| [Windows OpenSSH 설치](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse), [키 관리](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement) | Client 설치, 관리자 ssh-agent 서비스 준비, 일반 사용자 ssh-add 등록을 분리한다. Verify는 Windows 도구 경로와 agent를 확인한다. |
| [OpenSSH 설정](https://man.openbsd.org/ssh_config) | BatchMode는 대화형 암호/확인을 막고 StrictHostKeyChecking=yes는 미확인/변경된 host key를 거부한다. passphrase 제거 또는 host 검증 해제 대신 agent와 최초 독립 검증을 준비한다. |
| [MySQL Mandatory Policies and Permissions](https://docs.oracle.com/en-us/iaas/mysql-database/doc/mandatory-policies-permissions.html) | 사용자 그룹과 request.principal.type='mysqldbsystem'인 DB resource principal 권한은 구분된다. NSG/VNIC 권한은 템플릿의 단일 compartment ID와 DB principal 조건으로 제한하며 기존 정책을 먼저 검토한다. 정책 조회/문자열 검색은 유효 권한 보증이 아니다. |

[12단계 배포 가이드](GETTING_STARTED.md)는 각 단계마다 콘솔/명령·값·정확한 설정 위치·정상/실패 결과를 연결한다. 단독 배포 사본의 상대 링크와 입력 JSON 경로는 `Test-PortableDocs.ps1`에서 검사한다. 공식 문서 재조회는 실제 계정의 IAM·무료 자격·capacity·TLS 접속 증거가 아니며 대상 계정이 없으면 해당 범위는 NOT_RUN이다.


## 온보딩 패치의 설치·콘솔 안내 근거 (2026-09-27 확인)

기존 인프라의 정책·상한·승인 조건은 변경하지 않았다. 다음은 신규 초보자 안내의 설치/메뉴 설명에 사용한 외부 자료다. 문서 확인은 이 패치의 Windows 설치·실계정 시험을 실행했다는 뜻이 아니다. 실제 메뉴는 콘솔 언어·계정 유형에 따라 다를 수 있다.

- PowerShell Windows 설치: https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows
- Terraform 공식 설치와 배포 파일: https://developer.hashicorp.com/terraform/install ; https://releases.hashicorp.com/terraform/1.16.4/
- Terraform 배포 검증: https://developer.hashicorp.com/terraform/tutorials/cli/verify-install
- OCI CLI manual/virtualenv 설치: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/climanualinst.htm
- 기존 계약과 일치하는 OCI CLI 버전 소스: https://github.com/oracle/oci-cli/tree/v3.94.0
- Python 3.12 Windows 긴 경로: https://docs.python.org/3.12/using/windows.html
- OCI 리전 관리: https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingregions.htm
- OCI compartment 관리: https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingcompartments.htm
- OCI API 키·configuration preview: https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm
- Windows OpenSSH 키/agent: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement
- MySQL NSG 필수 정책: https://docs.oracle.com/en-us/iaas/mysql-database/doc/mandatory-policies-permissions.html
- MySQL Windows ZIP: https://dev.mysql.com/doc/refman/8.4/en/windows-install-archive.html
- 선택적인 공인 IPv4 조회 서비스: https://www.ipify.org/ (외부 요청 시 접속 IP가 해당 서비스에 전달됨)

Terraform 1.16.4는 신규 설치 안내의 구체적 예시다. 기존 지원 버전은 강제로 바꾸지 않으며 기존 `Validate.ps1`로 해당 PC에서 다시 검증한다. OCI CLI는 기존 코드가 정상 빈 목록을 3.94.0에 한해 해석하므로 이 버전을 고정한다. 마법사의 입력 형식 검사/후보 선택은 위 공식 조건이나 실계정 조회를 대신하지 않는다.
