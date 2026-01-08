output "container_app_fqdn" {
  value = azurerm_container_app.app.ingress[0].fqdn
}

output "custom_domain" {
  value = azurerm_container_app_custom_domain.domain.name
}
