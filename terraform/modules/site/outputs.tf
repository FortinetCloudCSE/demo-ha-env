output "inspection_vpc_id" {
  value = aws_vpc.inspection.id
}
output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.this.id
}
output "spoke_vpc_ids" {
  value = { for k, v in aws_vpc.spoke : k => v.id }
}
output "spoke_instance_private_ips" {
  value = { for k, v in aws_instance.spoke : k => v.private_ip }
}
output "primary" {
  value = {
    instance_id = aws_instance.primary.id
    port1_ip    = aws_network_interface.primary_port1.private_ip
    port3_ip    = aws_network_interface.primary_port3.private_ip
    mgmt_ip     = aws_network_interface.primary_port4.private_ip                   # port4, management VPC (no EIP)
    mgmt_eip    = var.enable_fgt_management_eip ? aws_eip.mgmt[0].public_ip : null # EIP on port3 (HA management)
  }
}
output "secondary" {
  value = {
    instance_id = aws_instance.secondary.id
    port1_ip    = aws_network_interface.secondary_port1.private_ip
    port3_ip    = aws_network_interface.secondary_port3.private_ip
    mgmt_ip     = aws_network_interface.secondary_port4.private_ip                 # port4, management VPC (no EIP)
    mgmt_eip    = var.enable_fgt_management_eip ? aws_eip.mgmt[1].public_ip : null # EIP on port3 (HA management)
  }
}
