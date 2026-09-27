resource "oci_core_instance" "server" {
  for_each                 = var.servers
  availability_domain      = each.value.availability_domain
  compartment_id           = var.compartment_ocid
  display_name             = "${var.project_name}-${each.key}"
  shape                    = "VM.Standard.E2.1.Micro"
  preserve_boot_volume     = true
  is_ai_enterprise_enabled = false
  freeform_tags            = merge(local.resource_tags, { role = each.value.role })

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    assign_ipv6ip    = false
    private_ip       = each.value.private_ip
    hostname_label   = each.key
    nsg_ids          = [oci_core_network_security_group.server[each.key].id]
  }

  source_details {
    source_type             = "image"
    source_id               = each.value.image_ocid
    boot_volume_size_in_gbs = tostring(each.value.boot_volume_size_in_gbs)
    boot_volume_vpus_per_gb = "10"
  }

  metadata = {
    ssh_authorized_keys = trimspace(file(pathexpand(var.ssh_public_key_path)))
    user_data = base64encode(templatefile("${path.module}/cloud-init/ubuntu.sh.tftpl", {
      ssh_cidr     = var.ssh_allowed_cidr
      public_https = each.value.public_https
      internal_rules = [for rule in values(var.internal_tcp_rules) : {
        source = var.servers[rule.source_server].private_ip
        port   = rule.port
      } if rule.destination_server == each.key]
    }))
  }

  lifecycle {
    precondition {
      condition = (data.oci_core_image.selected[each.key].operating_system == "Canonical Ubuntu" &&
        contains(["22.04", "24.04"], data.oci_core_image.selected[each.key].operating_system_version) &&
        data.oci_core_image_shape.selected[each.key].shape == "VM.Standard.E2.1.Micro" &&
      try(tonumber(data.oci_core_image.selected[each.key].size_in_mbs) <= each.value.boot_volume_size_in_gbs * 1024, false))
      error_message = "고정 이미지가 Ubuntu 22.04/24.04 AMD Micro와 호환되지 않거나 boot volume이 너무 작습니다."
    }
    precondition {
      condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( [^\\r\\n]*)?$", trimspace(file(pathexpand(var.ssh_public_key_path))))) && !strcontains(file(pathexpand(var.ssh_public_key_path)), "PRIVATE KEY")
      error_message = "SSH 공개키 형식을 확인하세요. 개인키를 전달할 수 없습니다."
    }
  }
  # Ensure initial package downloads can use the intended NSG egress rules.
  depends_on = [oci_core_network_security_group_security_rule.web_egress, oci_core_network_security_group_security_rule.dns_egress]
}
