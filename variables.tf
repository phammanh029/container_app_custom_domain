variable "location" {
  type    = string
  default = "westeurope"
}

variable "resource_group_name" {
  type    = string
  default = "aca-managed-cert-test-rg"
}

# Existing DNS zone (Azure DNS)
variable "dns_zone_name" {
  type    = string
  default = "az.codeleap.net"
}

# Resource group that contains the existing DNS zone
variable "dns_zone_resource_group" {
  type = string
}

# Full hostname we want
variable "hostname" {
  type    = string
  default = "mp1.az.codeleap.net"
}

# Relative record name inside zone az.codeleap.net
variable "relative_record_name" {
  type    = string
  default = "mp1"
}


variable "subscription_id" {
  type = string
}