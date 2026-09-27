# OCI 입력값 수집표 — 로컬 전용 예제

이 파일은 Terraform 코드가 아닙니다. 실제 값을 적을 때 `OCI_INPUTS.private.md` 등으로 복사하고, 먼저 Git 제외를 확인하세요. 개인키 원문·비밀번호·MFA를 적지 않습니다.

| 항목 | 내 값 / 확인 상태 |
|---|---|
| home region | REPLACE_ME |
| 콘솔 선택 region | REPLACE_ME |
| account type | REPLACE_ME |
| compartment 이름 | REPLACE_ME |
| compartment OCID | REPLACE_ME |
| 기존 VM과 shape | REPLACE_ME |
| 기존 boot/block volume 합계 | REPLACE_ME |
| 기존 volume backup 수 | REPLACE_ME |
| 기존 Always Free MySQL | REPLACE_ME |
| MySQL.Free 제공 확인 | 미확인 |
| 선택 가능한 MySQL 버전 | REPLACE_ME |
| 기존 Always Free Autonomous DB 수 | REPLACE_ME |
| OCI config 파일 경로 | REPLACE_ME |
| OCI profile 이름 | REPLACE_ME |
| API private key 경로 | 로컬에만 보관 |
| SSH public key 경로 | REPLACE_ME |
| SSH private key 경로 | 로컬에만 보관 |
| SSH 관리 공인 IPv4 /32 | REPLACE_ME |
| project name | translacat |
| server-1 역할 | 미정 |
| server-2 역할 | 미정 |
| OS / 유지할 버전 | Ubuntu / 확인 필요 |
| 논리 DB 1 이름·용도 | REPLACE_ME |
| 논리 DB 2 이름·용도 | translacat_chat / Chat |
| 추가 논리 DB | 필요할 때만 |
| Oracle Autonomous DB 개수 | 0 (기본) |
| public HTTP/HTTPS 필요 서버 | 미정, 기본 개방 안 함 |
| 실제 apply 승인 | 아직 승인 안 함 |
| 기존 자원 삭제/이전 승인 | 이번 작업에서는 승인 안 함 |

초기 계획: AMD Micro 2대 + 무료 MySQL DB System 1개. 서버의 애플리케이션 배치는 별도 확정하며, 실제 무료 자격·사용량·capacity를 확인한 뒤 적용합니다.
