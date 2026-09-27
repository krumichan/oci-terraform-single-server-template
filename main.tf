locals {
  resource_tags = { project = var.project_name, managed_by = "terraform" }
  vcn_cidr      = "10.0.0.0/16"
  public_cidr   = "10.0.1.0/24"
  private_cidr  = "10.0.2.0/24"
  mysql_ip      = "10.0.2.10"
  web_egress = merge([for name in keys(var.servers) : {
    for port in [80, 443] : "${name}-${port}" => { server = name, port = port }
  }]...)
  dns_egress = merge([for name in keys(var.servers) : {
    for protocol in ["6", "17"] : "${name}-${protocol}" => { server = name, protocol = protocol }
  }]...)
}

# These reads supplement, but never replace, tenancy-wide Preflight usage checks.
data "oci_identity_region_subscriptions" "account" {
  tenancy_id = var.tenancy_ocid
}

data "oci_core_image" "selected" {
  for_each = var.servers
  image_id = each.value.image_ocid
}

data "oci_core_image_shape" "selected" {
  for_each   = var.servers
  image_id   = each.value.image_ocid
  shape_name = "VM.Standard.E2.1.Micro"
}
