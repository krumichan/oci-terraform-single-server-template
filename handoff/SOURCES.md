# 공식 문서 확인 기록

확인일: 2026-09-27. 공개 문서 확인이며 실제 OCI 계정 조회·배포 검증은 수행하지 않았습니다. 문서는 변경될 수 있으므로 Codex 실행일에 재확인합니다.

## S1

**OCI Always Free Resources**

출처: `https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm`

확인 범위: AMD 최대 2대, home region, Compute boot/block 합계 200 GB, idle 회수, 자원 한도. 본문은 A1을 1,500 OCPU-hours/9,000 GB-hours 및 2 OCPU/12 GB로 표시하고 있어 과거 안내값을 고정 사용하지 않는다.

## S2

**Oracle MySQL HeatWave Free Cloud Trial / Always Free**

출처: `https://www.oracle.com/mysql/free/`

확인 범위: Always Free standalone MySQL DB System 1개, 50 GB 데이터/로그, 50 GB backup. 마케팅 페이지에는 Arm 최대 4개라는 표현이 있어 S1의 상세 안내와 차이가 있다. 본 제안은 AMD 기본으로 이 충돌에 의존하지 않는다.

## S3

**MySQL Supported Shapes**

출처: `https://docs.oracle.com/en-us/iaas/mysql-database/doc/supported-shapes.html`

확인 범위: MySQL.Free: 2 ECPU/8 GiB, HeatWave.Free: 16 GiB/1 node. 실제 계정 지원 여부와 무료 조건은 별도 확인한다.

## S4

**Always Free Autonomous AI Database**

출처: `https://docs.oracle.com/en-us/iaas/autonomous-database-serverless/doc/autonomous-always-free.html`

확인 범위: 최대 2개, 각각 20 GB, home region, private endpoint 및 backup/restore 제약, 비활성 정지/회수 정책. 무료 DB의 세션 수는 요약 페이지와 차이가 있어 이 패키지는 해당 수치를 정책 값으로 사용하지 않는다.

## S5

**Connecting to a MySQL DB System**

출처: `https://docs.oracle.com/en-us/iaas/mysql-database/doc/connecting-db-system1.html`

확인 범위: DB endpoint는 인터넷 직접 접속 불가. Compute/Bastion/VPN 등 접근 경로 사용; 인터넷 공개를 권장하지 않음.

## S6

**OCI Cloud Free Tier FAQ**

출처: `https://www.oracle.com/cloud/free/faq/`

확인 범위: Trial과 Always Free 구분, 30일/300달러, SLA 미제공. 무료 계정 추가 생성을 해결책으로 사용하지 않는다.

## S7

**Required Keys and OCIDs**

출처: `https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm`

확인 범위: API signing key/SSH key 구분, OCID와 fingerprint, 콘솔 API 키 생성과 config preview. preview region은 콘솔에서 선택한 리전이다.

## S8

**Terraform OCI: oci_mysql_mysql_db_system**

출처: `https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/mysql_mysql_db_system.html`

확인 범위: MySQL DB System 리소스와 shape_name, backup/deletion/data-storage 설정. 실제 구현은 선택한 provider 버전 schema를 확인해야 한다. MySQL에 Autonomous 전용 is_free_tier 필드를 임의로 추가하지 않는다.

## S9

**HashiCorp: Manage sensitive data**

출처: `https://developer.hashicorp.com/terraform/language/manage-sensitive-data`

확인 범위: sensitive는 마스킹이며 State/plan에 비밀이 남을 수 있음. write-only/ephemeral은 Terraform/provider 지원 및 사용 가능 문맥 확인 필요.

## S10

**HashiCorp: Validate your infrastructure**

출처: `https://developer.hashicorp.com/terraform/language/validate`

확인 범위: check 실패는 경고이며 기본적으로 실행을 차단하지 않음. 차단에는 validation/precondition 등 적절한 기법 사용.

## S11

**OCI Budgets**

출처: `https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/budgetsoverview.htm`

확인 범위: Budget은 soft limit과 알림이며 지출을 자동 차단하는 hard cap이 아니다.

## S12

**OCI Resource Manager: Always Free resources**

출처: `https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources_Launching.htm`

확인 범위: OCI Resource Manager를 이용한 Terraform 실행 선택지. 다른 실행 경로와 State 이중 관리 방지 필요.

## S13

**Creating a MySQL DB System**

출처: `https://docs.oracle.com/en-us/iaas/mysql-database/doc/creating-db-system.html`

확인 범위: 생성 템플릿, storage/backup, deletion protection, version 선택. 무료 전용 정책과 일반 유료 템플릿의 기본값을 혼동하지 않는다.

## S14

**OpenAI: Custom instructions with AGENTS.md**

출처: `https://developers.openai.com/codex/guides/agents-md`

확인 범위: Codex 프로젝트 지침을 전달하는 AGENTS.md 안내. 이번 지시서는 기존 AGENTS.md를 보존하면서 별도 task 문서를 읽도록 전달한다.

## 출처 해석 원칙

공식 요약·마케팅·상세 문서도 숫자가 다를 수 있습니다. 계정 quota가 높다고 그만큼 무료라는 뜻은 아니며, 문서상 무료 shape가 있어도 해당 리전의 즉시 공급을 보장하지 않습니다. 무료 상한과 실제 계정 제공/잔여량을 모두 확인하고 불일치는 보수적으로 중단합니다.

지시서에 적힌 보안 정책, 파일 구조, 스크립트 역할과 완료 기준은 이 사용자 작업을 위한 설계 요구사항입니다. Oracle이 해당 구조 전체를 제공하거나 보증한다는 뜻은 아닙니다.
