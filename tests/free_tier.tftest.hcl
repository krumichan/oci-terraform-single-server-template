# Every run is PLAN with a mocked provider. No OCI auth, networking, or apply.
mock_provider "oci" {
  mock_data "oci_identity_region_subscriptions" {
    defaults = {
      region_subscriptions = [{ is_home_region = true, region_name = "ap-tokyo-1", region_key = "NRT", state = "READY", tenancy_id = "ocid1.tenancy.oc1..mock" }]
    }
  }
  mock_data "oci_core_image" {
    defaults = { operating_system = "Canonical Ubuntu", operating_system_version = "24.04", size_in_mbs = "47694" }
  }
  mock_data "oci_core_image_shape" {
    defaults = { shape = "VM.Standard.E2.1.Micro" }
  }
}

variables {
  tenancy_ocid              = "ocid1.tenancy.oc1..mock"
  compartment_ocid          = "ocid1.compartment.oc1..mock"
  region                    = "ap-tokyo-1"
  home_region               = "ap-tokyo-1"
  project_name              = "offline"
  ssh_public_key_path       = "tests/fixtures/mock.pub"
  ssh_allowed_cidr          = "203.0.113.10/32"
  mysql_availability_domain = "MOCK:AP-TOKYO-1-AD-1"
  mysql_admin_password      = "MockOnly-Password987!"
  servers = {
    server-1 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mockone", private_ip = "10.0.1.10" }
    server-2 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mocktwo", private_ip = "10.0.1.11" }
  }
}

run "default_two_vm_mysql" {
  command = plan
  assert {
    condition     = length(oci_core_instance.server) == 2 && length(oci_mysql_mysql_db_system.free) == 1 && length(oci_database_autonomous_database.free) == 0
    error_message = "기본 구성은 VM2 + MySQL1 + Autonomous0이어야 합니다."
  }
  assert {
    condition     = alltrue([for vm in oci_core_instance.server : vm.shape == "VM.Standard.E2.1.Micro" && vm.source_details[0].boot_volume_size_in_gbs == "50" && vm.source_details[0].boot_volume_vpus_per_gb == "10" && vm.preserve_boot_volume])
    error_message = "AMD/boot50GiB/vpus10/boot 보존 정책이 달라졌습니다."
  }
  assert {
    condition     = oci_mysql_mysql_db_system.free[0].shape_name == "MySQL.Free" && oci_mysql_mysql_db_system.free[0].data_storage_size_in_gb == 50 && !oci_mysql_mysql_db_system.free[0].is_highly_available && !oci_mysql_mysql_db_system.free[0].data_storage[0].is_auto_expand_storage_enabled
    error_message = "무료 MySQL shape/storage/HA/확장 정책을 확인하세요."
  }
  assert {
    condition     = oci_mysql_mysql_db_system.free[0].backup_policy[0].retention_in_days == 1 && !oci_mysql_mysql_db_system.free[0].backup_policy[0].pitr_policy[0].is_enabled && oci_mysql_mysql_db_system.free[0].deletion_policy[0].is_delete_protected
    error_message = "MySQL 백업/삭제 보호 정책을 확인하세요."
  }
  assert {
    condition     = length(oci_core_network_security_group_security_rule.https) == 0 && alltrue([for rule in oci_core_network_security_group_security_rule.mysql_ingress : rule.source_type == "CIDR_BLOCK" && contains(["10.0.1.10/32", "10.0.1.11/32"], rule.source) && rule.tcp_options[0].destination_port_range[0].min == 3306]) && oci_core_subnet.private.prohibit_public_ip_on_vnic
    error_message = "MySQL은 허용 VM /32에서만 private 연결해야 합니다."
  }
}

run "single_vm_mysql_off" {
  command = plan
  variables {
    mysql_enabled        = false
    mysql_admin_password = null
    servers = {
      server-1 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mockone", private_ip = "10.0.1.10" }
    }
  }
  assert {
    condition     = length(oci_core_instance.server) == 1 && length(oci_mysql_mysql_db_system.free) == 0 && length(oci_core_network_security_group_security_rule.mysql_ingress) == 0
    error_message = "단일 VM / MySQL OFF 회귀입니다."
  }
}

run "map_order_and_pinned_images" {
  command = plan
  variables {
    servers = {
      server-2 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mocktwo", private_ip = "10.0.1.11" }
      server-1 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mockone", private_ip = "10.0.1.10" }
    }
  }
  assert {
    condition     = keys(oci_core_instance.server) == ["server-1", "server-2"] && oci_core_instance.server["server-1"].source_details[0].source_id == "ocid1.image.oc1.ap-tokyo-1.mockone" && oci_core_instance.server["server-2"].create_vnic_details[0].private_ip == "10.0.1.11"
    error_message = "map 입력 순서가 resource key/image/IP를 바꾸면 안 됩니다."
  }
}

run "explicit_https_and_internal_only" {
  command = plan
  variables {
    servers = {
      server-1 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mockone", private_ip = "10.0.1.10", public_https = true }
      server-2 = { availability_domain = "MOCK:AP-TOKYO-1-AD-1", image_ocid = "ocid1.image.oc1.ap-tokyo-1.mocktwo", private_ip = "10.0.1.11" }
    }
    internal_tcp_rules = { api = { source_server = "server-1", destination_server = "server-2", port = 8080 } }
  }
  assert {
    condition     = keys(oci_core_network_security_group_security_rule.https) == ["server-1"] && oci_core_network_security_group_security_rule.internal_ingress["api"].source == "10.0.1.10/32"
    error_message = "HTTPS 선택과 내부 통신 범위가 다릅니다."
  }
}

run "autonomous_one" {
  command = plan
  variables {
    autonomous_databases       = { analytics = { db_name = "catdata", whitelisted_ips = ["203.0.113.10/32"] } }
    autonomous_admin_passwords = { analytics = "MockOnly-Pass6789!" }
  }
  assert {
    condition     = length(oci_database_autonomous_database.free) == 1 && oci_database_autonomous_database.free["analytics"].is_free_tier && oci_database_autonomous_database.free["analytics"].data_storage_size_in_gb == 20 && oci_database_autonomous_database.free["analytics"].is_mtls_connection_required
    error_message = "Autonomous는 무료20GB/mTLS 모드여야 합니다."
  }
}

run "autonomous_two" {
  command = plan
  variables {
    autonomous_databases = {
      first  = { db_name = "catfirst", whitelisted_ips = ["203.0.113.10/32"] }
      second = { db_name = "catsecond", whitelisted_ips = ["203.0.113.10/32"] }
    }
    autonomous_admin_passwords = { first = "MockOnly-Pass6789!", second = "MockOnly-Pass9876!" }
  }
  assert {
    condition     = length(oci_database_autonomous_database.free) == 2
    error_message = "Autonomous 2개 옵션 회귀입니다."
  }
}

run "reject_third_vm" {
  command = plan
  variables {
    servers = {
      server-1 = { availability_domain = "MOCK:AD", image_ocid = "ocid1.image.oc1.mockone", private_ip = "10.0.1.10" }
      server-2 = { availability_domain = "MOCK:AD", image_ocid = "ocid1.image.oc1.mocktwo", private_ip = "10.0.1.11" }
      server-3 = { availability_domain = "MOCK:AD", image_ocid = "ocid1.image.oc1.mockthree", private_ip = "10.0.1.12" }
    }
  }
  expect_failures = [var.servers]
}

run "reject_over_200_gib" {
  command = plan
  variables {
    servers = {
      server-1 = { availability_domain = "MOCK:AD", image_ocid = "ocid1.image.oc1.mockone", private_ip = "10.0.1.10", boot_volume_size_in_gbs = 150 }
      server-2 = { availability_domain = "MOCK:AD", image_ocid = "ocid1.image.oc1.mocktwo", private_ip = "10.0.1.11", boot_volume_size_in_gbs = 100 }
    }
  }
  expect_failures = [var.servers]
}

run "reject_home_region_mismatch" {
  command = plan
  variables { region = "ap-osaka-1" }
  expect_failures = [oci_core_vcn.main]
}

run "reject_public_ssh" {
  command = plan
  variables { ssh_allowed_cidr = "0.0.0.0/0" }
  expect_failures = [var.ssh_allowed_cidr]
}

run "reject_paid_bypass" {
  command = plan
  variables { free_tier_only = false }
  expect_failures = [var.free_tier_only]
}

run "reject_public_autonomous_acl" {
  command = plan
  variables {
    autonomous_databases       = { analytics = { db_name = "catdata", whitelisted_ips = ["0.0.0.0/0"] } }
    autonomous_admin_passwords = { analytics = "MockOnly-Pass6789!" }
  }
  expect_failures = [var.autonomous_databases]
}

run "reject_third_autonomous" {
  command = plan
  variables {
    autonomous_databases = {
      first  = { db_name = "catfirst", whitelisted_ips = ["203.0.113.10/32"] }
      second = { db_name = "catsecond", whitelisted_ips = ["203.0.113.10/32"] }
      third  = { db_name = "catthird", whitelisted_ips = ["203.0.113.10/32"] }
    }
    autonomous_admin_passwords = { first = "MockOnly-Pass6789!", second = "MockOnly-Pass9876!", third = "MockOnly-Pass4321!" }
  }
  expect_failures = [var.autonomous_databases]
}

run "reject_incompatible_image" {
  command = plan
  override_data {
    target = data.oci_core_image.selected["server-1"]
    values = { operating_system = "Oracle Linux", operating_system_version = "9", size_in_mbs = "47694" }
  }
  expect_failures = [oci_core_instance.server["server-1"]]
}

run "reject_missing_mysql_secret" {
  command = plan
  variables { mysql_admin_password = null }
  expect_failures = [var.mysql_admin_password]
}
