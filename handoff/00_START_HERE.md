# OCI 무료 인프라 — Codex 작업 인계 패키지

작성일: 2026-09-27 / 대상: Windows 로컬 Terraform 실행

이 패키지는 **첨부 템플릿을 개선할 작업 지시서와 사전 준비 가이드**입니다. 완성된 Terraform 구현물이나 배포 성공 보고서가 아닙니다. OCI 계정에 접속하거나 리소스를 생성·변경·삭제하지 않았습니다.

## 권장 목표

- 기본: AMD Always Free VM 2대 + Always Free MySQL DB System 1개.
- DB System 내부에 서비스별 논리 DB와 전용 사용자를 분리합니다. 예: 언어학습 DB, `translacat_chat`. 물리 DB System 2개라는 뜻은 아닙니다.
- Oracle Autonomous Database는 별도 엔진입니다. 최대 2개 생성 기능은 선택 옵션이며 기본 배포에서 꺼 둡니다.
- ARM 전환, 유료 리소스 대체, 기존 서비스 이전, 기존 DB 삭제는 자동으로 진행하지 않습니다.

정책과 제공 여부는 실행일 공식 문서 및 대상 테넌시에서 다시 확인합니다. 서버가 생성된다는 사실과 TranslaCat의 모든 서비스를 충분한 성능으로 운영할 수 있다는 사실은 별도입니다.

## 사용법

1. 원래 Terraform 저장소에 작업용 브랜치를 준비합니다. 기존 미커밋 작업을 삭제하거나 덮어쓰지 않습니다.
2. 이 디렉터리를 저장소 안에 `handoff/`라는 이름으로 복사합니다. 기존 루트 README나 AGENTS.md를 덮어쓰지 않습니다.
3. `OCI_INPUT_GUIDE.md`를 보며 정보를 수집합니다. 실제 값을 기록하기 전에 `.gitignore`에 `OCI_INPUTS.private.md`와 실제 tfvars/State/plan의 제외 규칙이 적용되었는지 확인합니다. 개인키·비밀번호는 대화에 붙여 넣지 않습니다.
4. Codex에 아래 지시문을 전달합니다. 모델/추론 설정은 사용자가 선택한 설정을 유지하며, 이 패키지는 별도 모델 ID나 CLI 옵션을 지정하지 않습니다.

```text
이 저장소의 기존 AGENTS.md와 handoff/CODEX_TASK.md를 읽고 작업해줘.
함께 있는 TEMPLATE_REVIEW.md, OCI_INPUT_GUIDE.md, SOURCES.md도 확인해줘.

목표는 OCI 무료 VM 2대와 무료 MySQL DB System 1개를 안전하게 배포할 수 있는
Terraform, 입력값 수집 가이드, 검증·배포·접속·정리 스크립트의 완성이야.
MySQL 내부의 서비스별 논리 DB 분리를 지원하고,
Oracle Autonomous Database 최대 2개는 기본 OFF인 별도 선택 옵션으로 만들어줘.

제안서만 작성하지 말고 실제 코드와 문서, 실행 가능한 테스트를 만들어줘.
계정값이 없어도 가능한 구현과 오프라인 테스트는 끝까지 진행해줘.
필요한 값은 어디서 찾는지와 로컬 어디에 입력하는지를 표로 정리해줘.

기존 운영 자원과 State는 건드리지 말고, 실제 OCI apply/destroy 및 DB 초기화는
대상 테넌시·리전·변경 plan을 보여준 뒤 별도 승인을 받은 범위에서만 실행해줘.
무엇을 실제 검증했고 무엇이 mock 또는 미검증인지 명확히 구분해줘.
```

## 파일 구성

| 파일 | 목적 |
|---|---|
| CODEX_TASK.md | 범위, 구현 요구사항, 안전장치, 테스트, 완료 기준 |
| OCI_INPUT_GUIDE.md | 계정·리전·키·한도·DB 준비 절차 |
| OCI_INPUTS.private.example.md | 로컬 기록용 입력값 수집표; Terraform 입력 파일 아님 |
| TEMPLATE_REVIEW.md | 첨부 ZIP 원본에 대한 정적 점검 결과 |
| SOURCES.md | 공식 문서 출처와 확인 범위 |

실제 값이 들어간 `OCI_INPUTS.private.md`, Terraform State, plan, DB 비밀번호와 개인키는 Git에 올리지 않습니다. 이 수집표는 배포 프로그램이 아니며, Codex가 구현하는 실제 설정 파일로 값을 옮겨야 합니다.
