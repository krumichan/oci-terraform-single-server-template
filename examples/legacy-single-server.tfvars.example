# =============================================================================
# Edit only this file for each OCI account/environment.
# Never commit this file because it contains account-specific information.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. OCI API authentication
# Copy these values from the API key configuration preview in OCI Console.
# -----------------------------------------------------------------------------
tenancy_ocid         = "ocid1.tenancy.oc1..REPLACE_ME"
user_ocid            = "ocid1.user.oc1..REPLACE_ME"
api_key_fingerprint  = "REPLACE:ME:WITH:API:KEY:FINGERPRINT"
api_private_key_path = "C:/Users/REPLACE_ME/.oci/oci_api_key.pem"
region               = "ap-tokyo-1"

# -----------------------------------------------------------------------------
# 2. Deployment target
# Use null to create resources in the root compartment (tenancy), or enter a
# compartment OCID such as ocid1.compartment.oc1..xxxx.
# AD name is resolved automatically; normally leave the number as 1 in Tokyo
# and Osaka.
# -----------------------------------------------------------------------------
compartment_ocid           = null
availability_domain_number = 1
# Osaka
# image_ocid = "ocid1.image.oc1.ap-osaka-1.aaaaaaaaudxjt4hf7itlnv5ypfo3itrfcjo2neet4dxg2tx6efv7za3om65a"
# Tokyo
# image_ocid = "ocid1.image.oc1.ap-tokyo-1.aaaaaaaanpyicxepxtwgiyflfzaytrl23byzfalycndm5e2yswaifjl2y7vq"
ssh_public_key             = "ssh-rsa REPLACE_ME"

# -----------------------------------------------------------------------------
# 3. Common resource name
# All OCI display names are generated automatically from this one value:
#   my-app-server
#   my-app-vcn
#   my-app-internet-gateway
#   my-app-public-route-table
#   my-app-security-list
#   my-app-public-subnet
# -----------------------------------------------------------------------------
project_name = "my-app"

# -----------------------------------------------------------------------------
# 4. Single server
# -----------------------------------------------------------------------------
instance_shape   = "VM.Standard.E2.1.Micro"
instance_os_user = "ubuntu"
assign_public_ip = true
install_docker   = true

# -----------------------------------------------------------------------------
# 5. Network CIDR blocks
# A new VCN, Internet Gateway, route table, security list, and subnet are
# created by this template.
# -----------------------------------------------------------------------------
vcn_cidr_block    = "10.0.0.0/16"
subnet_cidr_block = "10.0.1.0/24"

# Replace the SSH source with your public IP address followed by /32.
# Add, remove, or change application ports as needed.
ingress_tcp_rules = [
  {
    description = "SSH"
    source      = "203.0.113.10/32"
    min_port    = 22
    max_port    = 22
  },
  {
    description = "Application"
    source      = "0.0.0.0/0"
    min_port    = 8080
    max_port    = 8080
  },
  {
    description = "Application"
    source      = "0.0.0.0/0"
    min_port    = 8000
    max_port    = 8000
  }
]

# The "project" tag is added automatically from project_name.
freeform_tags = {
  "managed-by" = "terraform"
}
