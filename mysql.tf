resource "oci_mysql_mysql_db_system" "free" {
  count                   = var.mysql_enabled ? 1 : 0
  compartment_id          = var.compartment_ocid
  availability_domain     = var.mysql_availability_domain
  display_name            = "${var.project_name}-mysql-free"
  shape_name              = "MySQL.Free"
  subnet_id               = oci_core_subnet.private.id
  nsg_ids                 = [oci_core_network_security_group.mysql[0].id]
  ip_address              = local.mysql_ip
  hostname_label          = "mysql"
  port                    = 3306
  port_x                  = 33060
  admin_username          = var.mysql_admin_username
  admin_password          = var.mysql_admin_password
  data_storage_size_in_gb = 50
  is_highly_available     = false
  database_management     = "DISABLED"
  freeform_tags           = local.resource_tags

  # Free DB always uses the latest service version; no version/window override.
  backup_policy {
    is_enabled        = true
    retention_in_days = 1
    soft_delete       = "DISABLED"
    pitr_policy {
      is_enabled = false
    }
  }
  data_storage {
    is_auto_expand_storage_enabled = false
  }
  deletion_policy {
    is_delete_protected        = true
    automatic_backup_retention = "RETAIN"
    final_backup               = "SKIP_FINAL_BACKUP"
  }
  read_endpoint {
    is_enabled = false
  }
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = try(length(trimspace(var.mysql_availability_domain)) > 0, false)
      error_message = "MySQL을 켠 경우 계정에서 확인한 mysql_availability_domain이 필요합니다."
    }
  }
}
