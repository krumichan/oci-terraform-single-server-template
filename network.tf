resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "${var.project_name}-vcn"
  dns_label      = "freevcn"
  freeform_tags  = local.resource_tags
  lifecycle {
    precondition {
      condition = var.region == var.home_region && length([
        for r in data.oci_identity_region_subscriptions.account.region_subscriptions : r.region_name
        if r.is_home_region && r.region_name == var.region && r.state == "READY"
      ]) == 1
      error_message = "배포 리전은 계정에서 조회한 READY home region이어야 합니다."
    }
  }
}

resource "oci_core_internet_gateway" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-internet-gateway"
  enabled        = true
  freeform_tags  = local.resource_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-public-route-table"
  freeform_tags  = local.resource_tags
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.public.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-private-no-internet-route"
  freeform_tags  = local.resource_tags
}

# Empty subnet lists are intentional: all grants are in explicit NSG rules.
# OCI's automatically created default security list is NOT attached.
resource "oci_core_security_list" "empty" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-empty-security-list"
  freeform_tags  = local.resource_tags
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.public_cidr
  display_name               = "${var.project_name}-public-subnet"
  dns_label                  = "servers"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.empty.id]
  prohibit_public_ip_on_vnic = false
  freeform_tags              = local.resource_tags
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.private_cidr
  display_name               = "${var.project_name}-private-db-subnet"
  dns_label                  = "database"
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.empty.id]
  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true
  freeform_tags              = local.resource_tags
}

resource "oci_core_network_security_group" "server" {
  for_each       = var.servers
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-${each.key}-nsg"
  freeform_tags  = local.resource_tags
}

resource "oci_core_network_security_group" "mysql" {
  count          = var.mysql_enabled ? 1 : 0
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${var.project_name}-mysql-nsg"
  freeform_tags  = local.resource_tags
}

resource "oci_core_network_security_group_security_rule" "ssh" {
  for_each                  = var.servers
  network_security_group_id = oci_core_network_security_group.server[each.key].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.ssh_allowed_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "https" {
  for_each                  = { for key, server in var.servers : key => server if server.public_https }
  network_security_group_id = oci_core_network_security_group.server[each.key].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "web_egress" {
  for_each                  = local.web_egress
  network_security_group_id = oci_core_network_security_group.server[each.value.server].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "dns_egress" {
  for_each                  = local.dns_egress
  network_security_group_id = oci_core_network_security_group.server[each.value.server].id
  direction                 = "EGRESS"
  protocol                  = each.value.protocol
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
  dynamic "tcp_options" {
    for_each = each.value.protocol == "6" ? [1] : []
    content {
      destination_port_range {
        min = 53
        max = 53
      }
    }
  }
  dynamic "udp_options" {
    for_each = each.value.protocol == "17" ? [1] : []
    content {
      destination_port_range {
        min = 53
        max = 53
      }
    }
  }
}

resource "oci_core_network_security_group_security_rule" "ntp_egress" {
  for_each                  = var.servers
  network_security_group_id = oci_core_network_security_group.server[each.key].id
  direction                 = "EGRESS"
  protocol                  = "17"
  destination               = "169.254.169.254/32"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
  udp_options {
    destination_port_range {
      min = 123
      max = 123
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mysql_ingress" {
  for_each                  = var.mysql_enabled ? var.servers : {}
  network_security_group_id = oci_core_network_security_group.mysql[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${each.value.private_ip}/32"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mysql_egress" {
  for_each                  = var.mysql_enabled ? var.servers : {}
  network_security_group_id = oci_core_network_security_group.server[each.key].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "${local.mysql_ip}/32"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "internal_ingress" {
  for_each                  = var.internal_tcp_rules
  network_security_group_id = oci_core_network_security_group.server[each.value.destination_server].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "${var.servers[each.value.source_server].private_ip}/32"
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "internal_egress" {
  for_each                  = var.internal_tcp_rules
  network_security_group_id = oci_core_network_security_group.server[each.value.source_server].id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = "${var.servers[each.value.destination_server].private_ip}/32"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}
