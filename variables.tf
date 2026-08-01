# ============================================================
# OCI authentication and deployment target
# Actual values are managed only in terraform.tfvars.
# ============================================================

variable "tenancy_ocid" {
  description = "OCI tenancy OCID."
  type        = string
}

variable "user_ocid" {
  description = "OCI user OCID used by the API signing key."
  type        = string
}

variable "api_key_fingerprint" {
  description = "Fingerprint of the OCI API signing key."
  type        = string
}

variable "api_private_key_path" {
  description = "Local path to the OCI API signing private key PEM file."
  type        = string
}

variable "region" {
  description = "OCI region identifier, for example ap-tokyo-1 or ap-osaka-1."
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID in which resources are created. Set null to use the root compartment (tenancy)."
  type        = string
  default     = null
  nullable    = true
}

variable "availability_domain_number" {
  description = "Availability Domain number. Single-AD regions normally use 1."
  type        = number
  default     = 1

  validation {
    condition     = var.availability_domain_number >= 1
    error_message = "availability_domain_number must be 1 or greater."
  }
}

variable "image_ocid" {
  description = "Region-specific OCI Compute image OCID."
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key registered on the instance."
  type        = string
}

# ============================================================
# Common resource naming
# ============================================================

variable "project_name" {
  description = "Common prefix used to generate all OCI resource display names. Use letters, numbers, and hyphens, and start with a letter."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9-]{0,39}$", var.project_name))
    error_message = "project_name must start with a letter, contain only letters, numbers, or hyphens, and be 1 to 40 characters long."
  }
}

# ============================================================
# Instance settings
# ============================================================

variable "instance_shape" {
  description = "OCI Compute shape, for example VM.Standard.E2.1.Micro."
  type        = string
  default     = "VM.Standard.E2.1.Micro"
}

variable "instance_os_user" {
  description = "Default OS user to add to the Docker group when Docker installation is enabled."
  type        = string
  default     = "ubuntu"
}

variable "assign_public_ip" {
  description = "Whether to assign a public IPv4 address to the instance."
  type        = bool
  default     = true
}

variable "install_docker" {
  description = "Whether cloud-init installs Docker and Docker Compose on first boot."
  type        = bool
  default     = true
}

# ============================================================
# Network settings
# This template creates a new VCN, Internet Gateway, route table,
# security list, and public subnet.
# ============================================================

variable "vcn_cidr_block" {
  description = "CIDR block of the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr_block" {
  description = "CIDR block of the public subnet. Must be inside vcn_cidr_block."
  type        = string
  default     = "10.0.1.0/24"
}

variable "ingress_tcp_rules" {
  description = "TCP ingress rules applied to the subnet security list."
  type = list(object({
    description = string
    source      = string
    min_port    = number
    max_port    = number
  }))

  validation {
    condition = alltrue([
      for rule in var.ingress_tcp_rules :
      rule.min_port >= 1 &&
      rule.max_port <= 65535 &&
      rule.min_port <= rule.max_port
    ])
    error_message = "Each TCP ingress rule must use ports from 1 to 65535, and min_port must not exceed max_port."
  }
}

variable "freeform_tags" {
  description = "Optional additional free-form tags applied to created resources. The project tag is added automatically from project_name."
  type        = map(string)
  default     = {}
}
