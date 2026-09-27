provider "oci" {
  config_file_profile = var.oci_profile
  tenancy_ocid        = var.tenancy_ocid
  region              = var.region
}
