resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

data "azurerm_dns_zone" "zone" {
  name                = var.dns_zone_name
  resource_group_name = var.dns_zone_resource_group
}

resource "azurerm_container_app_environment" "cae" {
  name                       = "cae-${random_string.suffix.result}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
}

resource "azurerm_container_app" "app" {
  name                         = "nginx-${random_string.suffix.result}"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "nginx"
      image  = "nginx:alpine"
      cpu    = 0.25
      memory = "0.5Gi"
    }
  }

  ingress {
    external_enabled           = true
    allow_insecure_connections = false
    target_port                = 80
    transport                  = "http"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
}

# CNAME: mp.az.codeleap.net -> <container app fqdn>
resource "azurerm_dns_cname_record" "cname" {
  name                = var.relative_record_name
  zone_name           = data.azurerm_dns_zone.zone.name
  resource_group_name = data.azurerm_dns_zone.zone.resource_group_name
  ttl                 = 300
  record              = azurerm_container_app.app.ingress[0].fqdn
}

# TXT: asuid.mp.az.codeleap.net -> <verification id>
resource "azurerm_dns_txt_record" "asuid" {
  name                = "asuid.${var.relative_record_name}"
  zone_name           = data.azurerm_dns_zone.zone.name
  resource_group_name = data.azurerm_dns_zone.zone.resource_group_name
  ttl                 = 300

  record {
    value = azurerm_container_app.app.custom_domain_verification_id
  }
}

# Poll until DNS resolves (better than fixed sleep)
resource "null_resource" "wait_for_dns" {
  depends_on = [
    azurerm_dns_cname_record.cname,
    azurerm_dns_txt_record.asuid
  ]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-lc"]

    command = <<BASH
set -euo pipefail

HOSTNAME="$${HOSTNAME}"
REL="$${REL}"
ZONE="$${ZONE}"
EXPECTED_TXT="$${EXPECTED_TXT}"
EXPECTED_CNAME="$${EXPECTED_CNAME}."

TXT_FQDN="asuid.$${REL}.$${ZONE}"
CNAME_FQDN="$${HOSTNAME}"

echo "Polling DNS (max ~10 minutes)..."
echo "  TXT   $${TXT_FQDN}  == $${EXPECTED_TXT}"
echo "  CNAME $${CNAME_FQDN} == $${EXPECTED_CNAME}"

for i in {1..60}; do
  TXT="$(dig +short TXT "$${TXT_FQDN}" | tr -d '"' | tail -n1 || true)"
  CNAME="$(dig +short CNAME "$${CNAME_FQDN}" | tail -n1 || true)"

  if [ "$${TXT}" = "$${EXPECTED_TXT}" ] && [ "$${CNAME}" = "$${EXPECTED_CNAME}" ]; then
    echo "DNS ready ✅"
    exit 0
  fi

  echo "Attempt $${i}/60: TXT='$${TXT}' CNAME='$${CNAME}' (waiting...)"
  sleep 10
done

echo "DNS not propagated in time. Verify records in Azure DNS." >&2
exit 1
BASH

    environment = {
      HOSTNAME       = var.hostname
      REL            = var.relative_record_name
      ZONE           = var.dns_zone_name
      EXPECTED_TXT   = azurerm_container_app.app.custom_domain_verification_id
      EXPECTED_CNAME = azurerm_container_app.app.ingress[0].fqdn
    }
  }
}

# Bind custom domain using Azure-managed cert:
# Omit container_app_environment_certificate_id for managed cert 
resource "azurerm_container_app_custom_domain" "domain" {
  name             = var.hostname
  container_app_id = azurerm_container_app.app.id

  certificate_binding_type = "Disabled"

  depends_on = [null_resource.wait_for_dns]
  lifecycle {
    // When using an Azure created Managed Certificate these values must be added to ignore_changes to prevent resource recreation.
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }
}

resource "azapi_resource" "managed_cert" {
  type      = "Microsoft.App/managedEnvironments/managedCertificates@2025-07-01"
  name      = var.hostname
  parent_id = azurerm_container_app_environment.cae.id
  location  = azurerm_resource_group.rg.location

  body = {
    properties = {
      subjectName             = var.hostname
      domainControlValidation = "CNAME"
    }
  }

  # Ensure hostname + DNS exist first
  depends_on = [
    azurerm_dns_cname_record.cname,
    azurerm_dns_txt_record.asuid,
    azurerm_container_app_custom_domain.domain
  ]
}

resource "azapi_update_resource" "bind_domain" {
  type        = "Microsoft.App/containerApps@2025-07-01"
  resource_id = azurerm_container_app.app.id

  body = {
    properties = {
      configuration = {
        ingress = {
          customDomains = [
            {
              name          = var.hostname
              bindingType   = "SniEnabled"
              certificateId = azapi_resource.managed_cert.id
            }
          ]
        }
      }
    }
  }

  depends_on = [azapi_resource.managed_cert]
}

# We need this resource to unbind the custom domain on destroy,
resource "azapi_resource_action" "unbind_domain_on_destroy" {
  type        = "Microsoft.App/containerApps@2025-07-01"
  resource_id = azurerm_container_app.app.id
  method      = "PATCH"
  when        = "destroy"

  body = {
    properties = {
      configuration = {
        ingress = {
          customDomains = [
            {
              name        = var.hostname
              bindingType = "Disabled"
            }
          ]
        }
      }
    }
  }
}