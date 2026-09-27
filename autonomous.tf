# Oracle engine opt-in. Always Free has no private endpoint: mTLS + IP ACL.
resource "oci_database_autonomous_database" "free" {
  for_each                            = var.autonomous_databases
  compartment_id                      = var.compartment_ocid
  display_name                        = "${var.project_name}-${each.key}"
  db_name                             = each.value.db_name
  db_workload                         = each.value.db_workload
  admin_password                      = var.autonomous_admin_passwords[each.key]
  is_free_tier                        = true
  cpu_core_count                      = 1
  data_storage_size_in_gb             = 20
  is_auto_scaling_enabled             = false
  is_auto_scaling_for_storage_enabled = false
  is_dedicated                        = false
  is_dev_tier                         = false
  is_local_data_guard_enabled         = false
  is_replicate_automatic_backups      = false
  is_mtls_connection_required         = true
  whitelisted_ips                     = each.value.whitelisted_ips
  license_model                       = "LICENSE_INCLUDED"
  freeform_tags                       = local.resource_tags
  lifecycle {
    prevent_destroy = true
  }
}
