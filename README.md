# OCI Terraform single-server template

OCI에 **새 네트워크와 Compute 인스턴스 한 대**를 만드는 범용 Terraform 템플릿입니다.

생성 대상:

- VCN
- Internet Gateway
- Public Route Table
- Security List
- Public Subnet
- Compute Instance 1대

## 파일 역할

- `terraform.tfvars`: 계정·리전·OCID·공통 프로젝트명·포트 등 사용자가 수정하는 유일한 설정 파일
- `variables.tf`: 변수의 타입과 설명만 선언
- `provider.tf`: `terraform.tfvars`의 인증 정보를 OCI Provider에 전달
- `main.tf`: 범용 리소스 정의 및 이름 자동 생성
- `outputs.tf`: 생성된 서버 IP와 OCID 출력
- `versions.tf`: Terraform 및 OCI Provider 버전 고정

## 공통 이름 설정

`terraform.tfvars`에서 다음 값 하나만 설정합니다.

```hcl
project_name = "my-app"
```

표시 이름은 자동으로 다음과 같이 생성됩니다.

```text
my-app-server
my-app-vcn
my-app-internet-gateway
my-app-public-route-table
my-app-security-list
my-app-public-subnet
my-app-server-vnic
```

OCI DNS 라벨은 하이픈을 제거한 `project_name`의 앞 9자를 이용해 자동 생성합니다.
예를 들어 `my-app`이면 `myappvcn`, `myappsubnet`, `myappserver`가 됩니다.

## 사용 순서

1. `terraform.tfvars`의 `REPLACE_ME` 값을 모두 교체합니다.
2. `project_name`을 원하는 공통 리소스명으로 변경합니다.
3. SSH 규칙의 `203.0.113.10/32`를 실제 공인 IP `/32`로 변경합니다.
4. 새 폴더에서 아래 명령을 실행합니다.

```powershell
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

## 중요한 주의사항

- 기존 프로젝트의 `terraform.tfstate`, `.terraform` 폴더를 복사하지 마세요.
- 기존 State를 이 템플릿에 연결하면 리소스 삭제·재생성 계획이 발생할 수 있습니다.
- `terraform.tfvars`, API PEM 개인키, SSH 개인키는 Git이나 다른 사람에게 공유하지 마세요.
- `image_ocid`는 선택한 리전과 Shape에서 사용할 수 있는 이미지 OCID를 입력해야 합니다.
- 이 템플릿은 기존 VCN을 재사용하지 않고 새 VCN을 생성합니다.
- 기본 Shape는 OCI 무료 범위에서 자주 사용하는 `VM.Standard.E2.1.Micro`이지만, 실제 무료 적용 여부와 리전 용량은 OCI 콘솔에서 확인하세요.
