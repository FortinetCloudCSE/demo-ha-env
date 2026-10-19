#====================================================================================================
# TWO SITES, EACH: inspection VPC + FGCP HA pair + TGW + east/west spokes.
# The two HA pairs are tied together by IPsec between their cluster EIPs.
# Cluster EIPs are allocated here so each site's bootstrap config can reference the other's address.
#====================================================================================================

resource "aws_eip" "cluster" {
  for_each = toset(["a", "b"])
  domain   = "vpc"
  tags     = { Name = "${local.prefix}-site-${each.key}-cluster-eip" }
}

locals {
  site_a_spokes = [var.site_a.east_cidr, var.site_a.west_cidr]
  site_b_spokes = [var.site_b.east_cidr, var.site_b.west_cidr]

  # Spoke instances are pinned at spoke_host_ip in the AZ1 workload subnet (the third /26 of the spoke /24),
  # so the VIP targets can be computed here without depending on the instances.
  site_a_ssh_forwards = [for f in var.site_a_ssh_forwards : merge(f, {
    target_ip = cidrhost(cidrsubnet(f.spoke == "east" ? var.site_a.east_cidr : var.site_a.west_cidr, 2, 2), var.spoke_host_ip)
  })]
  site_b_ssh_forwards = [for f in var.site_b_ssh_forwards : merge(f, {
    target_ip = cidrhost(cidrsubnet(f.spoke == "east" ? var.site_b.east_cidr : var.site_b.west_cidr, 2, 2), var.spoke_host_ip)
  })]

  site_a_extra_config = templatefile("${path.module}/templates/ssh-forwards.tpl", {
    site_label    = "site-a"
    admin_sources = var.ssh_admin_sources
    ssh_forwards  = local.site_a_ssh_forwards
  })
  site_b_extra_config = templatefile("${path.module}/templates/ssh-forwards.tpl", {
    site_label    = "site-b"
    admin_sources = var.ssh_admin_sources
    ssh_forwards  = local.site_b_ssh_forwards
  })
}

module "site_a" {
  source = "./modules/site"

  site_name           = "site-a"
  cp                  = var.cp
  env                 = var.env
  aws_region          = var.aws_region
  availability_zone_1 = local.availability_zone_1
  availability_zone_2 = local.availability_zone_2

  inspection_cidr    = var.site_a.inspection_cidr
  east_cidr          = var.site_a.east_cidr
  west_cidr          = var.site_a.west_cidr
  remote_spoke_cidrs = local.site_b_spokes
  remote_east_cidr   = var.site_b.east_cidr
  remote_west_cidr   = var.site_b.west_cidr
  site_index         = 1

  tunnel_name               = "to-site-b"
  peer_public_ip            = aws_eip.cluster["b"].public_ip
  ipsec_psk                 = local.ipsec_psk
  cluster_eip_allocation_id = aws_eip.cluster["a"].id
  tgw_cidr_blocks           = [var.tgw_cidr_blocks["site_a"]]
  extra_config              = length(var.site_a_ssh_forwards) > 0 ? local.site_a_extra_config : ""

  management_vpc_cidr = var.vpc_cidr_management

  management_cidr_sg         = var.management_cidr_sg
  management_subnet_az1_id   = aws_subnet.management_public_az1.id
  management_subnet_az2_id   = aws_subnet.management_public_az2.id
  management_subnet_az1_cidr = aws_subnet.management_public_az1.cidr_block
  management_subnet_az2_cidr = aws_subnet.management_public_az2.cidr_block
  management_sg_id           = aws_security_group.fortigate_management.id
  mgmt_host_ips              = var.fortigate_mgmt_host_ips["site_a"]
  enable_fgt_management_eip  = var.enable_fgt_management_eip
  fortimanager_ip            = local.fortimanager_ip
  fortianalyzer_ip           = local.fortianalyzer_ip

  keypair                   = var.keypair
  fortigate_instance_type   = var.fortigate_instance_type
  fortigate_ami_id          = data.aws_ami.fortigate.id
  fortigate_admin_password  = local.fortigate_admin_password
  ha_group_name             = "${var.cp}-${var.env}-site-a"
  ha_password               = local.ha_password
  license_type              = var.license_type
  primary_license_file      = var.site_a.primary_license_file
  secondary_license_file    = var.site_a.secondary_license_file
  primary_fortiflex_token   = var.site_a.primary_fortiflex_token
  secondary_fortiflex_token = var.site_a.secondary_fortiflex_token

  enable_spoke_instances = var.enable_spoke_instances
  spoke_instance_type    = var.spoke_instance_type
  spoke_host_ip          = var.spoke_host_ip
}

module "site_b" {
  source = "./modules/site"

  site_name           = "site-b"
  cp                  = var.cp
  env                 = var.env
  aws_region          = var.aws_region
  availability_zone_1 = local.availability_zone_1
  availability_zone_2 = local.availability_zone_2

  inspection_cidr    = var.site_b.inspection_cidr
  east_cidr          = var.site_b.east_cidr
  west_cidr          = var.site_b.west_cidr
  remote_spoke_cidrs = local.site_a_spokes
  remote_east_cidr   = var.site_a.east_cidr
  remote_west_cidr   = var.site_a.west_cidr
  site_index         = 2

  tunnel_name               = "to-site-a"
  peer_public_ip            = aws_eip.cluster["a"].public_ip
  ipsec_psk                 = local.ipsec_psk
  cluster_eip_allocation_id = aws_eip.cluster["b"].id
  tgw_cidr_blocks           = [var.tgw_cidr_blocks["site_b"]]
  extra_config              = length(var.site_b_ssh_forwards) > 0 ? local.site_b_extra_config : ""

  management_vpc_cidr = var.vpc_cidr_management

  management_cidr_sg         = var.management_cidr_sg
  management_subnet_az1_id   = aws_subnet.management_public_az1.id
  management_subnet_az2_id   = aws_subnet.management_public_az2.id
  management_subnet_az1_cidr = aws_subnet.management_public_az1.cidr_block
  management_subnet_az2_cidr = aws_subnet.management_public_az2.cidr_block
  management_sg_id           = aws_security_group.fortigate_management.id
  mgmt_host_ips              = var.fortigate_mgmt_host_ips["site_b"]
  enable_fgt_management_eip  = var.enable_fgt_management_eip
  fortimanager_ip            = local.fortimanager_ip
  fortianalyzer_ip           = local.fortianalyzer_ip

  keypair                   = var.keypair
  fortigate_instance_type   = var.fortigate_instance_type
  fortigate_ami_id          = data.aws_ami.fortigate.id
  fortigate_admin_password  = local.fortigate_admin_password
  ha_group_name             = "${var.cp}-${var.env}-site-b"
  ha_password               = local.ha_password
  license_type              = var.license_type
  primary_license_file      = var.site_b.primary_license_file
  secondary_license_file    = var.site_b.secondary_license_file
  primary_fortiflex_token   = var.site_b.primary_fortiflex_token
  secondary_fortiflex_token = var.site_b.secondary_fortiflex_token

  enable_spoke_instances = var.enable_spoke_instances
  spoke_instance_type    = var.spoke_instance_type
  spoke_host_ip          = var.spoke_host_ip
}
