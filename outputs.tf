output "instance_ocid" {
  description = "OCID of the created Compute instance."
  value       = oci_core_instance.server.id
}

output "instance_public_ip" {
  description = "Public IPv4 address of the instance."
  value       = oci_core_instance.server.public_ip
}

output "instance_private_ip" {
  description = "Private IPv4 address of the instance."
  value       = oci_core_instance.server.private_ip
}

output "availability_domain" {
  description = "Resolved Availability Domain name."
  value       = data.oci_identity_availability_domain.selected.name
}

output "vcn_ocid" {
  description = "OCID of the created VCN."
  value       = oci_core_vcn.main.id
}

output "subnet_ocid" {
  description = "OCID of the created public subnet."
  value       = oci_core_subnet.public.id
}
