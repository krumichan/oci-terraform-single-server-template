output "deployment" {
  description = "승인 전 확인할 대상. 비밀 출력 없음."
  value = {
    tenancy_ocid     = var.tenancy_ocid
    compartment_ocid = var.compartment_ocid
    region           = var.region
    project_name     = var.project_name
  }
}

output "servers" {
  value = { for key, server in oci_core_instance.server : key => {
    id                  = server.id
    public_ip           = server.public_ip
    private_ip          = var.servers[key].private_ip
    availability_domain = server.availability_domain
    image_ocid          = var.servers[key].image_ocid
    role                = var.servers[key].role
    ssh_user            = "ubuntu"
  } }
}

output "mysql" {
  description = "private endpoint 정보. 비밀번호/연결 문자열은 출력하지 않습니다."
  value = var.mysql_enabled ? {
    id         = oci_mysql_mysql_db_system.free[0].id
    private_ip = local.mysql_ip
    port       = 3306
    hostname   = "mysql.database.freevcn.oraclevcn.com"
    version    = oci_mysql_mysql_db_system.free[0].mysql_version
    admin_user = var.mysql_admin_username
  } : null
}

output "autonomous_databases" {
  description = "Oracle 엔진 선택 옵션. Wallet은 콘솔에서 별도로 받아 안전하게 보관합니다."
  value = { for key, db in oci_database_autonomous_database.free : key => {
    id            = db.id
    db_name       = db.db_name
    mtls_required = true
  } }
}

output "network" {
  value = {
    vcn_id            = oci_core_vcn.main.id
    public_subnet_id  = oci_core_subnet.public.id
    private_subnet_id = oci_core_subnet.private.id
  }
}
