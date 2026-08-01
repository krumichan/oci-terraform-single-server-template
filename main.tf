locals {
  deployment_compartment_ocid = coalesce(var.compartment_ocid, var.tenancy_ocid)

  # OCI display names are generated from a single project_name value.
  instance_display_name         = "${var.project_name}-server"
  vcn_display_name              = "${var.project_name}-vcn"
  internet_gateway_display_name = "${var.project_name}-internet-gateway"
  route_table_display_name      = "${var.project_name}-public-route-table"
  security_list_display_name    = "${var.project_name}-security-list"
  subnet_display_name           = "${var.project_name}-public-subnet"

  # OCI VCN/subnet DNS labels must be short alphanumeric values.
  # Remove hyphens and limit the common prefix so each generated label is <= 15 chars.
  dns_prefix              = substr(lower(replace(var.project_name, "-", "")), 0, 9)
  vcn_dns_label           = "${local.dns_prefix}vcn"
  subnet_dns_label        = "${local.dns_prefix}subnet"
  instance_hostname_label = "${local.dns_prefix}server"

  resource_tags = merge(
    var.freeform_tags,
    {
      "project" = var.project_name
    }
  )

  docker_user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose
    usermod -aG docker ${var.instance_os_user}
    systemctl enable --now docker
  EOT
}

# Resolve the tenant-specific Availability Domain name from a simple number.
data "oci_identity_availability_domain" "selected" {
  compartment_id = var.tenancy_ocid
  ad_number       = var.availability_domain_number
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

resource "oci_core_vcn" "main" {
  compartment_id = local.deployment_compartment_ocid
  cidr_blocks     = [var.vcn_cidr_block]
  display_name    = local.vcn_display_name
  dns_label       = local.vcn_dns_label
  freeform_tags   = local.resource_tags
}

resource "oci_core_internet_gateway" "public" {
  compartment_id = local.deployment_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = local.internet_gateway_display_name
  enabled        = true
  freeform_tags  = local.resource_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = local.deployment_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = local.route_table_display_name
  freeform_tags  = local.resource_tags

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.public.id
  }
}

resource "oci_core_security_list" "main" {
  compartment_id = local.deployment_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = local.security_list_display_name
  freeform_tags  = local.resource_tags

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  dynamic "ingress_security_rules" {
    for_each = var.ingress_tcp_rules

    content {
      description = ingress_security_rules.value.description
      protocol    = "6"
      source      = ingress_security_rules.value.source

      tcp_options {
        min = ingress_security_rules.value.min_port
        max = ingress_security_rules.value.max_port
      }
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id = local.deployment_compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = var.subnet_cidr_block
  display_name   = local.subnet_display_name
  dns_label      = local.subnet_dns_label
  route_table_id = oci_core_route_table.public.id

  security_list_ids          = [oci_core_security_list.main.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.resource_tags
}

# -----------------------------------------------------------------------------
# Single Compute instance
# -----------------------------------------------------------------------------

resource "oci_core_instance" "server" {
  availability_domain = data.oci_identity_availability_domain.selected.name
  compartment_id      = local.deployment_compartment_ocid
  display_name        = local.instance_display_name
  shape               = var.instance_shape
  freeform_tags       = local.resource_tags

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = var.assign_public_ip
    display_name     = "${local.instance_display_name}-vnic"
    hostname_label   = local.instance_hostname_label
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  metadata = merge(
    {
      ssh_authorized_keys = trimspace(var.ssh_public_key)
    },
    var.install_docker ? {
      user_data = base64encode(local.docker_user_data)
    } : {}
  )
}
