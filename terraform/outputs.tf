output "fortigate_ami" {
  description = "FortiGate AMI resolved from fortios_version"
  value       = { id = data.aws_ami.fortigate.id, name = data.aws_ami.fortigate.name }
}
output "fortimanager_ami" {
  value = var.enable_fortimanager ? { id = data.aws_ami.fortimanager[0].id, name = data.aws_ami.fortimanager[0].name } : null
}
output "fortianalyzer_ami" {
  value = var.enable_fortianalyzer ? { id = data.aws_ami.fortianalyzer[0].id, name = data.aws_ami.fortianalyzer[0].name } : null
}

output "management" {
  value = {
    vpc_id            = aws_vpc.management.id
    fortimanager_ip   = var.enable_fortimanager ? local.fortimanager_ip : null
    fortimanager_eip  = var.enable_fortimanager && var.enable_fortimanager_public_ip ? aws_eip.fortimanager[0].public_ip : null
    fortianalyzer_ip  = var.enable_fortianalyzer ? local.fortianalyzer_ip : null
    fortianalyzer_eip = var.enable_fortianalyzer && var.enable_fortianalyzer_public_ip ? aws_eip.fortianalyzer[0].public_ip : null
  }
}

output "cluster_eips" {
  description = "IPsec endpoints: each HA pair's cluster EIP (follows the master)"
  value       = { site_a = aws_eip.cluster["a"].public_ip, site_b = aws_eip.cluster["b"].public_ip }
}

output "site_a" {
  value = {
    inspection_vpc_id  = module.site_a.inspection_vpc_id
    transit_gateway_id = module.site_a.transit_gateway_id
    spoke_vpc_ids      = module.site_a.spoke_vpc_ids
    spoke_instances    = module.site_a.spoke_instance_private_ips
    primary            = module.site_a.primary
    secondary          = module.site_a.secondary
  }
}
output "site_b" {
  value = {
    inspection_vpc_id  = module.site_b.inspection_vpc_id
    transit_gateway_id = module.site_b.transit_gateway_id
    spoke_vpc_ids      = module.site_b.spoke_vpc_ids
    spoke_instances    = module.site_b.spoke_instance_private_ips
    primary            = module.site_b.primary
    secondary          = module.site_b.secondary
  }
}
