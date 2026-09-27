# 첨부 템플릿 정적 점검 기록

대상: `oci-terraform-single-server-template(1).zip`  
작성일: 2026-09-27  
원본 ZIP SHA-256: `bb8593167b8c4d0d0eb76ec21ee526da757671fc9e05496f10f63f5319fae70e`

ZIP 안의 실제 텍스트 파일을 직접 읽어 확인했습니다. 아래 `파일:줄`은 압축 내부 해당 파일의 줄 번호이며 Files 검색 엔진의 줄 번호가 아닙니다. 원본을 수정하거나 Terraform validate/plan/apply를 실행하지 않았습니다. Git 전체 과거 이력의 비밀 스캔도 수행하지 않았습니다.

## 발견 사항

| 항목 | 원본에서 확인한 내용 | 개선 요구 |
|---|---|---|
| Compute | main.tf의 `oci_core_instance.server` 단일 resource, count/for_each 없음 | 안정된 map key 기반 1~2대 지원 |
| DB | .tf 구성에 MySQL/Autonomous resource 없음 | MySQL 기본 및 Autonomous 선택 구성 |
| Network | 새 VCN/public subnet/security list 한 세트 | 공유 VCN 유지, VM별 접근 규칙, DB private 경로 |
| Volume | source_details에 boot volume 크기 미지정 | 크기 명시 및 기존 사용분 포함 무료 한도 검증 |
| 비용 검사 | 임의 instance_shape 문자열, 전체 테넌시 사용량/무료 차단 없음 | 허용 shape 및 quota/사용량/plan 정책 검증 |
| 앱 포트 | terraform.tfvars가 8080, 8000을 전체 인터넷에 허용 | 기본 폐쇄, 필요한 경로만 명시 허용 |
| Git 제외 | .gitignore에서 terraform.tfvars 제외가 주석 상태 | example만 추적, 실제 값 제외, tracked 여부 확인 |
| plan 파일 | README는 `-out=tfplan`, .gitignore는 `*.tfplan`만 제외 | 확장자 없는 tfplan 또는 전용 .plans/도 제외 |
| 이미지 | 필수 image_ocid가 없고 예시들은 주석 처리 | 리전/shape 호환 이미지 선택과 고정 흐름 |
| Docker | Ubuntu apt 기반 docker.io/docker-compose 설치 | 대상 OS 검증, Compose v2 및 완료/실패 확인 |
| 공급자 | OCI provider = 8.5.0, Terraform >=1.5.0,<2.0.0 | 잠금 버전 기준 schema 검사, 필요시에만 변경 |
| 패키징 | .git 디렉터리 포함 | 공유용 배포 ZIP에서 .git 및 민감 파일 제외 |

`terraform.tfvars`에는 REPLACE_ME 예시가 다수 들어 있습니다. `.gitignore` 문제는 실제 개인키 유출을 입증하는 것이 아니라, 앞으로 실제 값을 넣었을 때 Git 추적될 위험을 의미합니다. 과거 Git 이력에 비밀이 없다고까지 판정한 것은 아닙니다.

## 근거 발췌

### 단일 VM resource

원본 `main.tf:120` 부근:

```hcl
120: resource "oci_core_instance" "server" {
121:   availability_domain = data.oci_identity_availability_domain.selected.name
122:   compartment_id      = local.deployment_compartment_ocid
123:   display_name        = local.instance_display_name
124:   shape               = var.instance_shape
125:   freeform_tags       = local.resource_tags
126: 
127:   create_vnic_details {
128:     subnet_id        = oci_core_subnet.public.id
```

### boot volume 크기 미지정

```hcl
134:   source_details {
135:     source_type = "image"
136:     source_id   = var.image_ocid
137:   }
138: 
```

### Git 제외 설정

원본 `.gitignore` 전체:

```gitignore
# Terraform runtime files
.terraform/
*.tfstate
*.tfstate.*
crash.log
crash.*.log

# Account-specific values and plans
#terraform.tfvars
*.tfvars.json
*.tfplan

# Private keys
*.pem
*.key
```

README의 `terraform plan -out=tfplan`과 위 `*.tfplan`은 서로 맞지 않습니다. `tfplan`에는 점과 확장자가 없으므로 해당 glob만으로는 제외되지 않습니다.

### 앱 포트 전체 인터넷 개방

원본 `terraform.tfvars`의 ingress 영역:

```hcl
 61: ingress_tcp_rules = [
 62:   {
 63:     description = "SSH"
 64:     source      = "203.0.113.10/32"
 65:     min_port    = 22
 66:     max_port    = 22
 67:   },
 68:   {
 69:     description = "Application"
 70:     source      = "0.0.0.0/0"
 71:     min_port    = 8080
 72:     max_port    = 8080
 73:   },
 74:   {
 75:     description = "Application"
 76:     source      = "0.0.0.0/0"
 77:     min_port    = 8000
 78:     max_port    = 8000
 79:   }
 80: ]
 81: 
 82: # The "project" tag is added automatically from project_name.
 83: freeform_tags = {
 84:   "managed-by" = "terraform"
```

### 고정 provider와 Docker 초기화

```hcl
terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "= 8.5.0"
    }
  }
}
```

```bash
 26:   docker_user_data = <<-EOT
 27:     #!/bin/bash
 28:     set -euxo pipefail
 29: 
 30:     apt-get update -y
 31:     DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose
 32:     usermod -aG docker ${var.instance_os_user}
 33:     systemctl enable --now docker
 34:   EOT
 35: }
```

## 판단

기존 템플릿이 잘못된 목적을 수행하는 것은 아닙니다. **단일 VM을 새 네트워크에 만드는 목적**에는 맞지만, 이번 사용자의 다중 VM·무료 MySQL·서비스별 DB·사용량 검사·초보자용 운영 흐름을 아직 제공하지 않습니다.

VCN/기본 provider/출력/명명 방식을 재사용하면서, 리소스 구조와 보안·무료 정책·문서·검증을 보강하는 작업으로 진행하는 것이 적합합니다. 원본을 폐기하거나 기존 OCI 자원을 지울 근거는 없습니다.
