# Codex 작업 지시서: OCI Always Free 배포 템플릿 완성

## 0. 작업 목표와 실행 권한

기존 `oci-terraform-single-server-template` 저장소를 출발점으로, 사용자가 Oracle Cloud 계정 하나를 준비한 상태에서 **입력값을 안내대로 채우고 검증 → plan 확인 → 승인된 apply → 접속 확인까지 진행할 수 있는 Terraform 및 한국어 가이드**를 완성한다.

설계 설명만으로 끝내지 않는다. 실제 저장소 파일을 수정하고 스크립트와 테스트를 구현한다. 계정 정보가 없더라도 가능한 코드 작성·정적 검증·mock 테스트를 완료한다.

현재 승인된 것은 코드·문서·테스트 작성이다. 실제 OCI 생성/수정/삭제, DB bootstrap, 권한 부여, 기존 서비스 중단·이전은 별도 명시적 승인 범위에서만 실행한다. 승인 전에는 read-only 조회와 plan까지 허용하며, 인증값 자체가 없으면 조회도 미실행으로 기록한다. `terraform test` 역시 실제 apply를 수행할 수 있으므로 승인 없는 실제 리소스 테스트를 하지 않는다.

기존 AGENTS.md와 미커밋 변경을 먼저 읽고 보존한다. 작업이 길다는 이유로 제안서만 제출하지 않는다. 모르는 값은 만들어내지 말고, 그 값에 의존하지 않는 작업을 계속한다.

## 1. 사용자 맥락과 경계

- 로컬은 Windows이며 PowerShell 중심의 복사 가능한 안내를 제공한다. Git Bash 명령은 별도 구분한다.
- TranslaCat의 기존 기술은 Spring Boot BE, FastAPI AI이며, 언어학습은 Ktor, Chat은 ASP.NET Core로 분리하는 방향이다.
- DB는 MySQL 호환을 유지한다. Oracle Cloud에서 실행한다는 이유로 애플리케이션 DB 엔진을 Oracle Database로 변경하지 않는다.
- Chat은 `translacat_chat`과 전용 DB 계정을 소유한다. 언어학습도 별도 논리 DB와 사용자로 나눈다. LL DB의 실제 명칭은 로컬 코드/설정이 제공되어 있으면 확인하고, 없으면 예시라고 표시한다.
- Chat 관련 Redis·Presence·실시간·worker 책임은 CHAT 쪽이다. 인프라 배치 때문에 BE에 Redis 접근 책임을 되돌리지 않는다.
- 서버 역할은 `server-1`, `server-2` 같은 안정된 키와 설명으로 설정 가능하게 한다. 새 VM에 어떤 앱을 올릴지는 이번 요청만으로 고정하지 않는다.
- AMD/x86를 기본으로 한다. ARM 전환이나 애플리케이션 이미지의 아키텍처 변경을 자동으로 하지 않는다.
- 이전 작업에서 특정 테스트 데이터의 초기화를 허용했더라도 이번 계정 전체의 삭제 권한으로 해석하지 않는다. 기존 VM·DB·운영 데이터와 State를 이번 작업의 초기화 대상으로 취급하지 않는다.
- 이번 작업은 인프라와 DB 접속 기반까지다. 다른 애플리케이션 저장소 수정, 전체 서비스 이전, DNS 전환, 기존 Redis/DB 종료는 범위 밖이다.

## 2. 기본 구성과 선택 옵션

### 기본 실행 경로

- 하나의 명시된 테넌시, 검증된 home region, 전용 compartment를 사용한다.
- 공유 VCN 1개, VM용 public subnet, DB용 private subnet 및 필요한 최소 routing을 구성한다.
- `VM.Standard.E2.1.Micro` 2대. OS는 호환되는 Ubuntu LTS이며 기존 버전 유지 가능성을 우선 확인한다.
- boot volume은 예시로 각 50 GB를 명시한다. 실제 이미지 최소 크기와 테넌시 합계 제한을 검증한다.
- Always Free MySQL DB System 1개. 현재 공식 지원 shape `MySQL.Free`를 후보로 삼고 실행일 provider schema와 대상 계정에서 검증한다.
- MySQL에는 서비스별 논리 database/schema와 전용 계정을 생성하는 **별도 명시적 bootstrap 단계**를 제공한다. 2개 또는 필요한 수의 논리 DB를 입력으로 설정할 수 있게 한다.
- MySQL HA, read replica, PITR, 자동 스토리지 증가, 유료 shape 및 cross-region backup을 기본으로 사용하지 않는다. 무료 서비스에서 허용/강제되는 backup 설정을 재확인한다.
- 분석용 HeatWave cluster는 앱 DB 운영에 필요하지 않으면 기본 OFF다. 지원할 경우에도 `HeatWave.Free` 1노드만 별도 선택하게 하고 무료 조건을 확인한다. 이를 두 번째 MySQL DB로 설명하지 않는다.

### 선택 실행 경로

1. 서버만: VM 1대 또는 2대, MySQL 생성 OFF. 외부의 기존 DB를 자동 수정하지 않는다.
2. 기본 권장: VM 2대 + 무료 MySQL DB System 1개 + 서비스별 논리 DB.
3. Oracle Autonomous Database: 0~2개, 기본 0. MySQL과 다른 엔진임을 문서·입력 화면에 명시한다. 현재 provider가 지원하는 `is_free_tier` 등 실제 필드를 검증하여 무료 모드만 허용한다.

선택 옵션 OFF→ON은 리소스 추가일 수 있지만 ON→OFF는 삭제 계획일 수 있다. 플래그 변경을 안전한 일시정지라고 설명하지 않는다. DB 삭제 보호를 유지하고 삭제는 별도 절차로 취급한다.

Oracle Autonomous Always Free는 현재 private endpoint 제약이 있으므로 MySQL과 동일한 private subnet 구조를 그대로 적용하지 않는다. 실제 제약에 맞춰 TLS/Wallet와 접근 허용 범위를 안내한다. 사용하지 않는 DB를 무료라는 이유만으로 생성하지 않는다. [S4]

## 3. 먼저 확인할 것

`TEMPLATE_REVIEW.md`를 참고하되 실제 작업 트리에서 다시 확인한다.

- 기존 파일, Terraform/provider lock, Git 추적 상태, 로컬 State 존재 여부.
- 기존 리소스가 이 State로 관리 중인지 여부. 신규 배포는 기존 State를 복사하지 않는다.
- 실행일 공식 OCI Always Free 정책, 대상 home region, 계정 타입, 이미 사용 중인 자원과 한도.
- Compute shape 지원 여부와 실제 host capacity는 다르다. 목록에 보인다고 생성 성공을 보장하지 않는다.
- MySQL.Free 제공 여부, 리전, 사용 가능 DB 버전, backup 정책, 한도와 계정 자격.
- Terraform OCI provider의 **잠긴 버전**이 필요한 리소스·필드를 지원하는지 확인한다. 첨부는 8.5.0으로 고정되어 있다. 필요할 때만 근거와 검증을 남기고 변경한다.
- MySQL 리소스에 Autonomous 전용 인자를 복사하거나 존재하지 않는 `is_free_tier` 인자를 만들어 넣지 않는다. [S8]

문서가 서로 다른 값을 안내하거나 계정 확인이 불가능하면 그 사실을 보고한다. 무료 자격을 확인할 수 없는 리소스를 유료 자원으로 대체하지 않는다. 예전 A1 4 OCPU/24 GB 안내를 근거 없이 재사용하지 않는다. 기본 범위는 AMD이므로 A1 구현을 추가할 필요는 없다. [S1, S2]

## 4. Terraform 구조와 사용자 경험

- root 구성은 읽기 쉽게 유지하고 network / compute / mysql / optional autonomous 등으로 필요한 수준만 모듈화한다. 불필요한 범용 프레임워크는 만들지 않는다.
- VM은 안정된 이름을 키로 하는 `map(object(...))`와 `for_each`를 사용한다. 배열 순서 변경으로 서버가 재생성되는 구조를 피한다.
- 기존 단일 서버 사용자를 위한 예제도 유지한다.
- 환경마다 비밀이 없는 `.example` 설정 파일을 제공하고, 사용자 실제 값은 Git 제외된 로컬 파일/OCI profile에 둔다.
- 키 내용 대신 API private key 경로와 SSH public key 경로 또는 공개키 문자열을 입력받는다. SSH 개인키는 Terraform metadata에 전달하지 않는다.
- 기본 인증 경로를 하나 명확히 선택한다. OCI config profile 방식을 권장 검토하되 변수 방식과 불필요하게 중복 입력시키지 않는다.
- 현재 region과 home region을 구분한다. 입력 region이 무료 자원 적용 home region과 다르면 기본 배포를 차단한다.
- 이미지 자동 검색은 후보 확인/초기 고정용으로 사용한다. 매 plan마다 최신 이미지 OCID가 바뀌어 기존 VM 교체를 유발하지 않도록, 선택한 이미지를 고정하는 흐름을 제공한다.
- OS/shape/architecture/image 호환성을 검사한다. image OCID의 리전 문자열만 수정하는 방식은 금지한다.
- 기존 VM을 새 모듈 주소로 옮기는 경우에는 정확한 `moved`/import 계획을 문서화한다. State 변경은 승인 전 실행하지 않는다.
- 기본 State는 개인 작업자에게 이해 가능한 방식으로 제공하고, 테넌시·리전·환경 단위로 분리한다. State 분실 시 중복 생성하는 대신 복구/import 절차를 안내한다.
- OCI Resource Manager GUI 배포는 선택 설명으로 제공할 수 있다. 지원한다고 주장하려면 schema.yaml, 인증 방식, 키 입력, 지원 Terraform 버전 차이를 확인한다. 로컬 경로가 필요한 root를 수정 없이 Resource Manager에 업로드하면 된다고 안내하지 않는다. 같은 리소스를 로컬과 Resource Manager의 서로 다른 State로 이중 관리하지 않는다. [S12]

## 5. 비용 및 무료 범위 보호 — 필수

`free_tier_only = true` 같은 정책을 기본으로 하고, 이번 제공 경로에서는 유료 배포로 전환하는 우회 스위치를 만들지 않는다.

필수 차단 항목:

- AMD Micro: 테넌시의 기존 사용분과 계획된 변경을 합산하여 2대 초과를 차단한다.
- MySQL: 무료 DB System 한도를 검사하고 기본 1개만 허용한다.
- Autonomous: 테넌시의 기존 무료 DB와 합산하여 2개 초과를 차단한다.
- Compute boot/block volume의 테넌시 합계, 보존된 boot volume, volume backup 수를 확인한다. DB 서비스의 전용 저장 용량과 Compute block-volume 무료 풀을 근거 없이 합산하지 않는다.
- 기존 State가 관리하는 리소스를 기존 사용량과 신규 예정 사용량으로 이중 계산하지 않는다.
- 다른 compartment의 사용분도 놓치지 않는다. 조회 권한 부족, pagination 누락, 알 수 없는 값이 있으면 비용 검증을 PASS로 처리하지 않는다.
- `create_before_destroy`나 교체 과정의 일시적 한도 초과를 탐지한다. 용량을 만들기 위해 기존 서버부터 삭제하지 않는다.
- paid shape, 유료 image/license, 과도한 volume 성능, HA/PITR/replica, 자동 확장, cross-region 기능, 불필요한 추가 서비스 생성은 차단/명시적 검토 대상이다.
- NAT, LB, OKE 등 기본 목적에 불필요한 리소스를 자동 생성하지 않는다. 모든 NAT/LB가 유료라고 단정하지 말고 필요성과 실제 요금을 따로 확인한다.
- account upgrade, home-region 변경 시도, 임의 신규 계정, 유료 shape fallback, 무한 capacity 재시도는 구현하지 않는다.

Terraform의 `check` 실패는 경고만 남길 수 있다. 비용 차단은 `validation`, `precondition` 및 실패 시 종료 코드가 0이 아닌 plan 정책 검사로 구현한다. 테스트로 실제 차단을 증명한다. [S10]

plan JSON 검사는 허용한 resource type/shape/옵션만 통과시키는 방향으로 하고, 중요한 unknown 값을 안전하다고 가정하지 않는다. plan과 State에는 비밀이 있을 수 있으므로 원본 JSON을 공유 로그에 출력하지 않는다.

Budget alert는 보조 수단이며 지출을 멈추는 hard cap이 아니다. Terraform 밖에서 생성한 자원, 사용량 과금, 정책 변경까지 이 템플릿이 100% 차단한다고 주장하지 않는다. 리소스별 무료 근거와 미확인 항목을 사용자에게 출력한다. [S11]

## 6. 네트워크와 서버 초기화

- 공유 VCN을 생성하고 서버별 NSG 중심의 최소 허용 정책을 사용한다. DB NSG 지원 여부는 provider schema로 확인하고, 필요하면 DB 전용 private subnet의 제한된 security list로 구현한다.
- SSH 22는 사용자의 현재 공인 IPv4 /32 또는 명시된 관리용 CIDR만 허용한다. 기본 `0.0.0.0/0` SSH는 차단한다.
- 앱 포트 8080/8000, DB 3306, Redis 6379를 인터넷에 자동 개방하지 않는다.
- public 서비스는 필요한 서버의 443 등을 명시적으로 선택할 때만 허용한다. 80은 인증서 발급/redirect 등 근거가 있을 때만 사용한다.
- 내부 서비스 통신은 허용한 서버/NSG와 포트 사이에서만 가능하게 한다. subnet security list와 NSG의 허용 규칙이 합쳐져 제한을 우회하지 않는지 검사한다.
- MySQL은 public endpoint를 만들지 않는다. VM→DB private 통신, 로컬 관리용 SSH tunnel 또는 Bastion 가이드를 제공한다. [S5]
- public subnet 내 public IP 없는 VM이 인터넷에 나갈 수 있다고 가정하지 않는다. 각 서버의 업데이트·컨테이너 pull·외부 AI 호출 egress 경로를 명시한다.
- OCI 네트워크 설정뿐 아니라 OS 방화벽 및 Docker port publishing을 함께 검증한다. 기존 iptables를 무작정 flush하지 않는다.
- cloud-init은 승인한 OS에서 검증하고 실패/완료 상태를 조회할 수 있게 한다. Docker Engine 및 Compose v2 지원을 확인한다.
- 설치 시 재시도는 제한하고 로그를 남기되 비밀을 출력하지 않는다. 앱·DB 비밀번호를 user_data에 넣지 않는다.
- 컨테이너 로그 rotation, 재부팅 후 Docker 기동과 데이터 보존 확인 절차를 제공한다.
- 서버당 메모리 1 GB를 고려한다. 무거운 이미지 빌드를 VM 안에서 강제하지 않으며 전체 앱 운용 가능 성능을 검증 없이 보장하지 않는다. swap은 RAM 대체나 성능 보장이 아니다.
- idle 회수 회피를 위한 허위 CPU 부하/무의미한 지속 요청을 구현하지 않는다. 정상적인 관측·백업·복구 가이드로 대응한다.

## 7. MySQL bootstrap과 데이터 안전

Terraform이 DB System을 만드는 것과 SQL database/user를 만드는 작업을 구분한다.

- 인프라 apply 이후 사용자가 별도로 실행할 수 있는 bootstrap 스크립트를 제공한다.
- 서비스별 schema/database 이름과 계정을 설정 가능하게 한다. 논리 DB 분리와 물리 인스턴스 분리의 차이를 명시한다.
- 관리자 계정을 앱 공용 계정으로 쓰지 않는다. 각 서비스 계정은 자기 DB에만 필요한 권한을 갖는다.
- DB명과 사용자명은 검증하고 SQL injection, shell interpolation, 비밀번호 로그 노출을 방지한다.
- 재실행 시 기존 데이터 DROP/TRUNCATE, 사용자 삭제, 임의 비밀번호 변경이 발생하지 않도록 한다. 명시적 password rotation은 별도 작업이다.
- 연결의 TLS 설정을 검증하고 진단한다. 인증서 검증을 끄는 것을 기본 해결책으로 삼지 않는다.
- 기존 프로젝트의 MySQL 8.4 계열 및 실제 드라이버/ORM 요구와 OCI 제공 버전을 확인한다. 버전 숫자를 추측하여 고정하지 않는다.
- 제공된 앱 코드가 없다면 EF Core/Exposed/JDBC 호환성은 미검증으로 표기하고 엔진 전환이나 마이그레이션 성공을 주장하지 않는다.
- 새 논리 DB와 권한 검증까지만 수행한다. 애플리케이션 테이블 마이그레이션은 각 서비스의 기존 Flyway/EF migrations 소유권에 맡긴다.
- DB System 삭제 보호 및 Terraform 차원의 파괴 방지 방법을 제공한다. `prevent_destroy`가 코드에서 resource를 제거한 상황까지 완전히 보호한다고 설명하지 않는다.
- 백업·복원 절차와 실제 무료 서비스의 제한을 문서화한다. 무료 DB를 한도보다 더 생성해야 하는 복원 실험은 무승인 수행하지 않는다.

## 8. 비밀·Git·State

- `.gitignore`의 `#terraform.tfvars`를 수정하고 비밀이 없는 example만 추적한다.
- 기존에 tfvars가 tracked라면 `.gitignore`만 추가해서 해결됐다고 하지 않는다. 실제 값이 아닌 안전한 example로 전환하고 추적 해제하되 사용자 로컬 값은 보존한다. Git history rewrite/force push는 별도 승인 없이는 하지 않는다.
- `*.tfvars`, `*.auto.tfvars`, JSON variants, `.env`, `OCI_INPUTS.private.md`, private keys, `.terraform/`, State와 backup, saved plan 및 JSON, runtime credentials를 적절히 제외한다.
- `.terraform.lock.hcl`는 유지한다. 단순히 `*.hcl` 전체를 제외하지 않는다.
- README에 `-out=tfplan`을 쓰면 확장자 없는 `tfplan`도 제외한다. 가능하면 `.plans/`처럼 전용 ignored 경로를 쓴다.
- `sensitive = true`는 화면 마스킹일 뿐 State 암호화가 아니다. 선택한 provider의 write-only/ephemeral 지원을 확인하지 않고 비밀이 State에 안 남는다고 주장하지 않는다. [S9]
- API 키·SSH 개인키·DB 비밀번호를 출력, Git commit, 공유 증적, cloud-init, 일반 output에 넣지 않는다. 필요한 값은 로컬 경로나 secure prompt로 받는다.
- State/plan은 최소 권한, 디스크 암호화/보호된 저장 위치와 별도 안전한 백업 방식을 안내한다.
- 배포 ZIP에는 `.git/`, `.terraform/`, 실제 tfvars, State, plan, 키를 넣지 않는다.

## 9. 스크립트 및 가이드 산출물

파일명은 구현상 조정할 수 있지만 다음 역할을 모두 제공한다.

| 역할 | 요구사항 |
|---|---|
| Setup / Init-Config | example 복사, 입력값 검증, 기존 값 덮어쓰기 방지, 비밀 없는 안내 |
| Preflight | 도구·인증·home region·compartment·권한·무료 자원 사용량 확인; 읽기 전용 |
| Validate | fmt/validate 및 오프라인 테스트; 클라우드 생성 금지 |
| Plan | saved plan과 민감값 제거 요약 생성; 무료 정책 검사; 삭제/교체 강조 |
| Apply | 사용자 승인 확인 후 정확히 검토한 saved plan 적용; 기본 자동 적용 없음 |
| DB Bootstrap | 승인된 신규 DB 대상, 논리 DB/사용자·권한 생성 및 재실행 안전성 |
| Verify | SSH/cloud-init/Docker/DB TLS/권한·비노출·재plan 확인 |
| Cleanup 안내 | 보호 해제·backup 영향·삭제 plan 확인 순서; 자동 삭제 없음 |

PowerShell에서는 native 명령 종료 코드를 확인하고 오류를 삼키지 않는다. `terraform plan -detailed-exitcode`의 0/1/2를 구분한다. `terraform apply savedplan`이 별도 Terraform 프롬프트 없이 적용될 수 있으므로 래퍼의 사전 승인 단계를 구현한다. `-auto-approve`를 기본 제공하지 않는다.

초보자용 README에 최소 다음 내용을 넣는다.

- 현재 무료 구성의 정확한 의미와 한도, 리전/계정 확인, Trial 크레딧과 Always Free 차이.
- API 키와 SSH 키의 차이, 각 값의 콘솔 위치와 로컬 입력 위치.
- 기존 사용자의 적용/신규 사용자의 적용 차이, State 보관, 기존 자원 가져오기 절차.
- Windows 첫 실행 순서 및 예시 출력, 에러 메시지별 해결.
- 서버/DB IP·OCID 조회, SSH 접속, private DB tunnel, 서비스별 connection 설정 예시(비밀 없음).
- 무료 DB 한도 초과, home-region 불일치, 권한 부족, image 호환 오류, out-of-capacity, Docker/cloud-init 실패, DB TLS/권한 오류 대응.
- 재실행과 변경 시 어떤 자원이 교체되는지, 이미지 업데이트 주의사항, 삭제 보호와 안전한 정리.
- 백업/복구와 idle 회수, 용량 부족, 무료 무과금 검토의 한계.

## 10. 테스트와 증거

최소 실행 항목:

- `terraform fmt -check -recursive`
- `terraform init -backend=false` 및 모든 실제 root의 `terraform validate`
- provider schema 확인과 lockfile 일관성 검사
- 오프라인 `terraform test` 또는 동등한 테스트; command=plan/mock 기반이며 실제 리소스 apply 없음
- PowerShell 스크립트 구문/단위 테스트, 인자·종료 코드·비밀 마스킹 검사
- 기본 2 VM + MySQL 1개 계획, 단일 VM 회귀, MySQL OFF, Autonomous OFF/1/2 등의 양성 케이스
- 세 번째 AMD, 두 번째 무료 MySQL, 세 번째 Autonomous, 200 GB 초과, 기존 사용분 초과, home-region 불일치, paid shape, SSH/DB/Redis 인터넷 노출, unknown 비용 조건 등의 음성 케이스
- 기존 관리 자원 이중 집계 방지, 교체 시 최대 동시 사용량, pagination/권한 부족 시 fail-closed
- bootstrap 재실행 시 데이터·계정 비파괴; 서비스 A 계정의 서비스 B DB 접근 거부
- 이미지 선택 고정 및 서버 map 순서 변경 시 불필요 교체 없음
- 예제·문서·스크립트의 변수명이 실제 구현과 일치

인증값과 실제 적용 승인이 있을 때만 live 검증한다.

- 적용된 테넌시/리전/compartment/리소스 수 및 무료 shape 증거.
- VM 2대 정상 기동, SSH, cloud-init 완료, Docker/Compose 확인.
- 승인된 신규 MySQL로 TLS 연결 및 논리 DB별 권한 검사.
- 외부에서 3306/6379 및 내부 앱 포트가 허용되지 않는지 확인.
- 동일 설정의 두 번째 plan에 의도치 않은 변경/교체 없음.
- 사용량/무료 분류 및 billing 확인. 단, 청구 반영 지연 때문에 생성 직후 0원만으로 장기 무과금을 증명했다고 하지 않는다.

mock은 OCI 실제 성공 증거가 아니다. 정적 검증과 실클라우드 검증을 구분한다.

## 11. 최종 보고와 완료 기준

다음 형식으로 보고한다.

1. 수정 파일과 구현한 실행 경로.
2. 공식 정책 확인일, 무료 근거, 계정에서 직접 확인한 항목/미확인 항목.
3. 실제 실행 명령·종료 코드·통과/실패/mock/미실행.
4. 남은 사용자 입력값: 필드 / 이유 / 콘솔 위치 / 로컬 입력 위치 / 비밀 여부.
5. 정확한 다음 실행 명령과 예상 출력; 아직 만들어지지 않은 파일의 명령을 제시하지 않는다.
6. 삭제·교체·비용·데이터 영향 및 live 승인 필요 범위.

상태는 아래와 같이 분리한다.

- `IMPLEMENTED_OFFLINE_VALIDATED_LIVE_NOT_RUN`: 구현/오프라인 검증 완료, 실제 생성 미실행.
- `LIVE_PLAN_VERIFIED_AWAITING_APPLY_APPROVAL`: 대상 계정 read-only/preflight/plan 확인, 적용 승인 대기.
- `LIVE_DEPLOYED_INFRA_VERIFIED`: 승인된 기본 인프라와 접속 검사 완료. 앱 전체 운영 검증 완료라는 뜻은 아님.
- `BLOCKED`: blocker와 이미 완료한 범위를 정확히 명시. 실패/미실행 테스트를 PASS로 바꾸지 않음.

가장 중요한 완료 기준: **사용자가 기본 설정만 채워 안전하게 검증·배포·접속·재실행할 수 있고, 무료 확인이 불가능하거나 파괴/비용 위험이 있으면 명확한 이유와 함께 멈추는 것**이다.
