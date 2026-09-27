terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  # Plan.ps1 isolates the path by tenancy, region, and environment.
  backend "local" {}

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "= 8.5.0"
    }
  }
}
