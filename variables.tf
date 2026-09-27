variable "tenancy_ocid" {
  description = "OCI profile과 일치하는 tenancy OCID."
  type        = string
  validation {
    condition     = can(regex("^ocid1\\.tenancy\\.", var.tenancy_ocid))
    error_message = "실제 tenancy OCID가 필요합니다."
  }
}

variable "compartment_ocid" {
  description = "기존 전용 compartment OCID. Root 자동 사용은 지원하지 않습니다."
  type        = string
  validation {
    condition     = can(regex("^ocid1\\.compartment\\.", var.compartment_ocid))
    error_message = "전용 compartment OCID가 필요합니다."
  }
}

variable "oci_profile" {
  description = "~/.oci/config의 API signing key profile 이름."
  type        = string
  default     = "TRANSLACAT"
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.oci_profile))
    error_message = "profile 이름은 영문, 숫자, _, -만 허용합니다."
  }
}

variable "region" {
  description = "배포 리전. 검증한 home_region과 같아야 합니다."
  type        = string
}

variable "home_region" {
  description = "계정에서 확인한 home region."
  type        = string
}

variable "free_tier_only" {
  description = "무료 전용 정책. 유료 전환 스위치가 아닙니다."
  type        = bool
  default     = true
  validation {
    condition     = var.free_tier_only
    error_message = "free_tier_only=false는 지원하지 않습니다."
  }
}

variable "project_name" {
  description = "리소스 표시 이름 접두사."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,29}$", var.project_name))
    error_message = "project_name은 소문자로 시작하는 소문자/숫자/하이픈 1~30자입니다."
  }
}

variable "ssh_public_key_path" {
  description = "SSH 공개키 .pub 경로. 개인키 금지."
  type        = string
  validation {
    condition     = can(regex("\\.pub$", var.ssh_public_key_path)) && fileexists(pathexpand(var.ssh_public_key_path))
    error_message = "존재하는 SSH 공개키 .pub 파일 경로가 필요합니다."
  }
}

variable "ssh_allowed_cidr" {
  description = "SSH 관리 IPv4 CIDR. 공인 IPv4/32 권장. /0 금지."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.ssh_allowed_cidr)) && try(tonumber(split("/", var.ssh_allowed_cidr)[1]) > 0, false)
    error_message = "SSH는 유효한 IPv4 CIDR만 허용하며 /0은 금지합니다."
  }
}

variable "servers" {
  description = "고정 key의 AMD 서버 1~2대. image OCID와 private IP를 한 번 선택하여 고정합니다."
  type = map(object({
    availability_domain     = string
    image_ocid              = string
    private_ip              = string
    role                    = optional(string, "미정")
    boot_volume_size_in_gbs = optional(number, 50)
    public_https            = optional(bool, false)
  }))
  validation {
    condition     = length(var.servers) >= 1 && length(var.servers) <= 2
    error_message = "AMD Micro는 1~2대만 허용합니다. 기존 tenancy 사용량은 별도 합산해야 합니다."
  }
  validation {
    condition = alltrue([for key, server in var.servers :
      can(regex("^[a-z][a-z0-9-]{0,14}$", key)) && can(regex("^ocid1\\.image\\.", server.image_ocid)) &&
      length(trimspace(server.availability_domain)) > 0 &&
      contains([for n in range(2, 255) : cidrhost("10.0.1.0/24", n)], server.private_ip) &&
      server.boot_volume_size_in_gbs >= 50 && server.boot_volume_size_in_gbs <= 200 && floor(server.boot_volume_size_in_gbs) == server.boot_volume_size_in_gbs
    ]) && length(distinct([for server in values(var.servers) : server.private_ip])) == length(var.servers)
    error_message = "서버 key는 DNS label 15자 이하, image OCID/AD는 명시값, private IP는 중복 없는 10.0.1.2~254, boot는 정수 50~200 GiB여야 합니다."
  }
  validation {
    condition     = sum([for server in values(var.servers) : server.boot_volume_size_in_gbs]) <= 200
    error_message = "계획한 boot만으로 200 GiB를 초과합니다. 기존/보존 volume도 Preflight에서 합산합니다."
  }
}

variable "internal_tcp_rules" {
  description = "필요한 VM 간 TCP 통신만 명시. 인터넷에는 개방하지 않습니다."
  type = map(object({
    source_server      = string
    destination_server = string
    port               = number
  }))
  default = {}
  validation {
    condition = alltrue([for rule in values(var.internal_tcp_rules) :
      contains(keys(var.servers), rule.source_server) && contains(keys(var.servers), rule.destination_server) &&
      rule.port >= 1 && rule.port <= 65535 && floor(rule.port) == rule.port
    ])
    error_message = "내부 규칙에는 정의된 서버 key와 정수 TCP port 1~65535가 필요합니다."
  }
}

variable "mysql_enabled" {
  description = "무료 MySQL 1개 생성. OFF 변경은 삭제 계획이며 중지가 아닙니다."
  type        = bool
  default     = true
}

variable "mysql_availability_domain" {
  description = "무료 MySQL을 사용할 availability domain 전체 이름."
  type        = string
  default     = null
}

variable "mysql_admin_username" {
  type        = string
  description = "앱에 사용하지 않는 MySQL 관리자 이름."
  default     = "dbadmin"
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{2,31}$", var.mysql_admin_username)) && !contains(["root", "admin", "administrator"], lower(var.mysql_admin_username))
    error_message = "관리자 이름은 영문 시작 3~32자이며 root/admin/administrator는 금지합니다."
  }
}

variable "mysql_admin_password" {
  description = "TF_VAR_mysql_admin_password로 주입. State/plan에도 저장되므로 보호가 필요합니다."
  type        = string
  sensitive   = true
  default     = null
  validation {
    condition = !var.mysql_enabled || try(
      length(var.mysql_admin_password) >= 8 && length(var.mysql_admin_password) <= 32 &&
      can(regex("[a-z]", var.mysql_admin_password)) && can(regex("[A-Z]", var.mysql_admin_password)) &&
    can(regex("[0-9]", var.mysql_admin_password)) && can(regex("[^A-Za-z0-9]", var.mysql_admin_password)), false)
    error_message = "MySQL 관리자 비밀번호는 8~32자이며 대문자/소문자/숫자/특수문자를 포함해야 합니다."
  }
}

variable "autonomous_databases" {
  description = "별도 Oracle 엔진 옵션(기본 OFF). MySQL과 무관하며 최대 2개."
  type = map(object({
    db_name         = string
    db_workload     = optional(string, "OLTP")
    whitelisted_ips = set(string)
  }))
  default = {}
  validation {
    condition = length(var.autonomous_databases) <= 2 && alltrue([for db in values(var.autonomous_databases) :
      can(regex("^[A-Za-z][A-Za-z0-9]{0,13}$", db.db_name)) && contains(["OLTP", "DW"], db.db_workload) &&
      length(db.whitelisted_ips) > 0 && alltrue([for cidr in db.whitelisted_ips :
        can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) > 0, false)
      ])
    ])
    error_message = "Autonomous는 0~2개, 영문 시작 영숫자 DB명 1~14자, OLTP/DW, /0 아닌 IPv4 CIDR allowlist가 필요합니다."
  }
}

variable "autonomous_admin_passwords" {
  description = "Autonomous와 같은 key의 비밀 map. TF_VAR_autonomous_admin_passwords JSON으로 주입."
  type        = map(string)
  sensitive   = true
  default     = {}
  validation {
    condition = alltrue([for key, db in var.autonomous_databases : try(
      length(var.autonomous_admin_passwords[key]) >= 12 && length(var.autonomous_admin_passwords[key]) <= 30 &&
      can(regex("[a-z]", var.autonomous_admin_passwords[key])) && can(regex("[A-Z]", var.autonomous_admin_passwords[key])) &&
      can(regex("[0-9]", var.autonomous_admin_passwords[key])) &&
      !strcontains(lower(var.autonomous_admin_passwords[key]), "admin") &&
      !strcontains(lower(var.autonomous_admin_passwords[key]), lower(db.db_name)) &&
    !can(regex("[\"\\s]", var.autonomous_admin_passwords[key])), false)])
    error_message = "Autonomous별 비밀번호는 12~30자(대문자/소문자/숫자 포함, 공백/큰따옴표/ADMIN/DB명 제외)입니다."
  }
}
