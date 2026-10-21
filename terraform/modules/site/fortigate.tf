#====================================================================================================
# FORTIGATE FGCP HA PAIR
#   port1 public  (inspection public subnet)   - cluster EIP follows the master, IPsec terminates here
#   port2 private (inspection private subnet)  - TGW-facing data plane
#   port3 ha-mgmt (inspection ha-mgmt subnet)  - heartbeat, config sync AND the HA management interface: public subnet,
#                                                an EIP per unit for GUI/SSH and the EC2 API
#   port4 mgmt    (MANAGEMENT VPC subnet)      - multi-VPC ENI, no EIP: FortiManager / FortiAnalyzer only (VRF 1, fgfm)
#====================================================================================================

#--- Security groups --------------------------------------------------------------------------------
resource "aws_security_group" "public" {
  name        = "${local.prefix}-fgt-public-sg"
  description = "FortiGate port1: open inbound, access controlled by FortiGate policy"
  vpc_id      = aws_vpc.inspection.id
  ingress {
    description = "All inbound (VIPs, IKE/NAT-T); filtered by FortiGate policy"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = var.public_ingress_cidrs
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.prefix}-fgt-public-sg" }
}

resource "aws_security_group" "private" {
  name        = "${local.prefix}-fgt-private-sg"
  description = "FortiGate port2: GRE from the TGW, plus this site VPC ranges and the remote site"
  vpc_id      = aws_vpc.inspection.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = concat([var.inspection_cidr], local.local_spoke_cidrs, var.remote_spoke_cidrs, var.tgw_cidr_blocks)
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.prefix}-fgt-private-sg" }
}

resource "aws_security_group" "ha_mgmt" {
  name        = "${local.prefix}-fgt-ha-mgmt-sg"
  description = "FortiGate port3: heartbeat, config sync and HA management"
  vpc_id      = aws_vpc.inspection.id
  ingress {
    description = "GUI from the admin CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "SSH from the admin CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "ping from the admin CIDRs"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "HA heartbeat and session/config sync (whole VPC: the standby heartbeat can leave port1 with a port1 source address)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.inspection.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.prefix}-fgt-ha-mgmt-sg" }
}

#--- IAM (FortiOS awsd needs this to move the EIP and repoint routes on failover) ---------------------
resource "aws_iam_role" "fortigate" {
  name = "${local.prefix}-fortigate-ha-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy" "fortigate" {
  name = "${local.prefix}-fortigate-ha-policy"
  role = aws_iam_role.fortigate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "HAGatherInfo"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAddresses",
          "ec2:DescribeInstances",
          "ec2:DescribeRouteTables",
          "ec2:DescribeVpcEndpoints",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRegions"
        ]
        Resource = "*"
      },
      {
        Sid      = "BootstrapBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.bootstrap.arn, "${aws_s3_bucket.bootstrap.arn}/*"]
      },
      {
        Sid      = "FailoverEIPs"
        Effect   = "Allow"
        Action   = ["ec2:AssociateAddress", "ec2:DisassociateAddress"]
        Resource = "*"
      },
      {
        Sid      = "FailoverVPCroutes"
        Effect   = "Allow"
        Action   = ["ec2:ReplaceRoute", "ec2:CreateRoute", "ec2:DeleteRoute"]
        Resource = "*"
      }
    ]
  })
}
resource "aws_iam_instance_profile" "fortigate" {
  name = "${local.prefix}-fortigate-ha-profile"
  role = aws_iam_role.fortigate.name
}

#--- Network interfaces -----------------------------------------------------------------------------
# index 0 = primary/AZ1, 1 = secondary/AZ2
locals {
  mgmt_subnet_ids   = [var.management_subnet_az1_id, var.management_subnet_az2_id]
  mgmt_subnet_cidrs = [var.management_subnet_az1_cidr, var.management_subnet_az2_cidr]
}

resource "aws_network_interface" "primary_port1" {
  subnet_id         = aws_subnet.public[0].id
  private_ips       = [cidrhost(local.public_cidrs[0], var.data_host_ip)]
  security_groups   = [aws_security_group.public.id]
  source_dest_check = false
  tags              = { Name = "${local.prefix}-fgt-primary-port1" }
}
resource "aws_network_interface" "primary_port2" {
  subnet_id         = aws_subnet.private[0].id
  private_ips       = [cidrhost(local.private_cidrs[0], var.data_host_ip)]
  security_groups   = [aws_security_group.private.id]
  source_dest_check = false
  tags              = { Name = "${local.prefix}-fgt-primary-port2" }
}
resource "aws_network_interface" "primary_port3" {
  subnet_id       = aws_subnet.ha_mgmt[0].id
  private_ips     = [cidrhost(local.ha_cidrs[0], var.data_host_ip)]
  security_groups = [aws_security_group.ha_mgmt.id]
  tags            = { Name = "${local.prefix}-fgt-primary-port3" }
}
resource "aws_network_interface" "primary_port4" {
  subnet_id         = local.mgmt_subnet_ids[0]
  private_ips       = [cidrhost(local.mgmt_subnet_cidrs[0], var.mgmt_host_ips[0])]
  security_groups   = [var.management_sg_id]
  source_dest_check = false
  tags              = { Name = "${local.prefix}-fgt-primary-port4-mgmt" }
}

resource "aws_network_interface" "secondary_port1" {
  subnet_id         = aws_subnet.public[1].id
  private_ips       = [cidrhost(local.public_cidrs[1], var.data_host_ip)]
  security_groups   = [aws_security_group.public.id]
  source_dest_check = false
  tags              = { Name = "${local.prefix}-fgt-secondary-port1" }
}
resource "aws_network_interface" "secondary_port2" {
  subnet_id         = aws_subnet.private[1].id
  private_ips       = [cidrhost(local.private_cidrs[1], var.data_host_ip)]
  security_groups   = [aws_security_group.private.id]
  source_dest_check = false
  tags              = { Name = "${local.prefix}-fgt-secondary-port2" }
}
resource "aws_network_interface" "secondary_port3" {
  subnet_id       = aws_subnet.ha_mgmt[1].id
  private_ips     = [cidrhost(local.ha_cidrs[1], var.data_host_ip)]
  security_groups = [aws_security_group.ha_mgmt.id]
  tags            = { Name = "${local.prefix}-fgt-secondary-port3" }
}
resource "aws_network_interface" "secondary_port4" {
  subnet_id         = local.mgmt_subnet_ids[1]
  private_ips       = [cidrhost(local.mgmt_subnet_cidrs[1], var.mgmt_host_ips[1])]
  security_groups   = [var.management_sg_id]
  source_dest_check = false
  tags              = { Name = "${local.prefix}-fgt-secondary-port4-mgmt" }
}

#--- Bootstrap config ---------------------------------------------------------------------------------
locals {
  fortiflex = var.license_type == "fortiflex"

  userdata_common = {
    admin_password          = var.fortigate_admin_password
    ha_group_name           = var.ha_group_name
    ha_password             = var.ha_password
    port1_mask              = cidrnetmask(local.public_cidrs[0])
    port2_mask              = cidrnetmask(local.private_cidrs[0])
    port3_mask              = cidrnetmask(local.ha_cidrs[0])
    port4_mask              = cidrnetmask(local.mgmt_subnet_cidrs[0])
    management_vpc_cidr     = var.management_vpc_cidr
    local_spoke_cidrs       = local.local_spoke_cidrs
    tgw_cidrs               = var.tgw_cidr_blocks
    local_east_cidr         = var.east_cidr
    local_west_cidr         = var.west_cidr
    remote_east_cidr        = var.remote_east_cidr
    remote_west_cidr        = var.remote_west_cidr
    intersite_tunnel_local  = local.intersite_tunnel_local
    intersite_tunnel_remote = local.intersite_tunnel_remote
    tunnel_name             = var.tunnel_name
    peer_public_ip          = var.peer_public_ip
    ipsec_psk               = var.ipsec_psk
    fortimanager_ip         = var.fortimanager_ip
    fortianalyzer_ip        = var.fortianalyzer_ip
    license_type            = var.license_type
    extra_config            = var.extra_config
    fgt_asn                 = var.fortigate_bgp_asn
    tgw_asn                 = aws_ec2_transit_gateway.this.amazon_side_asn
    connect_peers = [for k in ["east", "west"] : {
      name        = k
      tgw_addr    = local.connect_tgw_addr[k]
      fgt_ip      = local.connect_bgp[k].fgt_ip
      tgw_ip1     = local.connect_bgp[k].tgw_ip1
      tgw_ip2     = local.connect_bgp[k].tgw_ip2
      vrf         = local.customer_vrf[k]
      local_cidr  = k == "east" ? var.east_cidr : var.west_cidr
      remote_cidr = k == "east" ? var.remote_east_cidr : var.remote_west_cidr
    }]
    # one GRE tunnel per customer through the IPsec tunnel to the other site
    intersite = [for k in ["east", "west"] : {
      name        = k
      key         = local.intersite_gre_key[k]
      fgt_ip      = local.intersite_inside[k].local
      peer_ip     = local.intersite_inside[k].remote
      vrf         = local.customer_vrf[k]
      remote_cidr = k == "east" ? var.remote_east_cidr : var.remote_west_cidr
    }]
  }

  primary_config = templatefile("${path.module}/templates/fgt-config.tpl", merge(local.userdata_common, {
    hostname        = "${local.prefix}-fgt-primary"
    ha_priority     = 255
    ha_peer_ip      = aws_network_interface.secondary_port3.private_ip
    port1_ip        = aws_network_interface.primary_port1.private_ip
    port1_gateway   = cidrhost(local.public_cidrs[0], 1)
    port2_ip        = aws_network_interface.primary_port2.private_ip
    port2_gateway   = cidrhost(local.private_cidrs[0], 1)
    port3_ip        = aws_network_interface.primary_port3.private_ip
    port4_ip        = aws_network_interface.primary_port4.private_ip
    port4_gateway   = cidrhost(local.mgmt_subnet_cidrs[0], 1)
    port3_gateway   = cidrhost(local.ha_cidrs[0], 1)
    fortiflex_token = var.primary_fortiflex_token
  }))

  secondary_config = templatefile("${path.module}/templates/fgt-config.tpl", merge(local.userdata_common, {
    hostname        = "${local.prefix}-fgt-secondary"
    ha_priority     = 1
    ha_peer_ip      = aws_network_interface.primary_port3.private_ip
    port1_ip        = aws_network_interface.secondary_port1.private_ip
    port1_gateway   = cidrhost(local.public_cidrs[1], 1)
    port2_ip        = aws_network_interface.secondary_port2.private_ip
    port2_gateway   = cidrhost(local.private_cidrs[1], 1)
    port3_ip        = aws_network_interface.secondary_port3.private_ip
    port4_ip        = aws_network_interface.secondary_port4.private_ip
    port4_gateway   = cidrhost(local.mgmt_subnet_cidrs[1], 1)
    port3_gateway   = cidrhost(local.ha_cidrs[1], 1)
    fortiflex_token = var.secondary_fortiflex_token
  }))
}

#--- Instances ----------------------------------------------------------------------------------------
resource "aws_instance" "primary" {
  ami                  = var.fortigate_ami_id
  instance_type        = var.fortigate_instance_type
  availability_zone    = var.availability_zone_1
  key_name             = var.keypair
  iam_instance_profile = aws_iam_instance_profile.fortigate.name
  user_data            = local.primary_userdata

  network_interface {
    network_interface_id = aws_network_interface.primary_port1.id
    device_index         = 0
  }
  network_interface {
    network_interface_id = aws_network_interface.primary_port2.id
    device_index         = 1
  }
  network_interface {
    network_interface_id = aws_network_interface.primary_port3.id
    device_index         = 2
  }
  # Multi-VPC ENI: lives in the management VPC subnet, attached to an instance in the inspection VPC.
  network_interface {
    network_interface_id = aws_network_interface.primary_port4.id
    device_index         = 3
  }

  tags       = { Name = "${local.prefix}-fgt-primary" }
  depends_on = [aws_vpc_endpoint.s3, aws_s3_object.config, aws_s3_object.license]
}

resource "aws_instance" "secondary" {
  ami                  = var.fortigate_ami_id
  instance_type        = var.fortigate_instance_type
  availability_zone    = var.availability_zone_2
  key_name             = var.keypair
  iam_instance_profile = aws_iam_instance_profile.fortigate.name
  user_data            = local.secondary_userdata

  network_interface {
    network_interface_id = aws_network_interface.secondary_port1.id
    device_index         = 0
  }
  network_interface {
    network_interface_id = aws_network_interface.secondary_port2.id
    device_index         = 1
  }
  network_interface {
    network_interface_id = aws_network_interface.secondary_port3.id
    device_index         = 2
  }
  network_interface {
    network_interface_id = aws_network_interface.secondary_port4.id
    device_index         = 3
  }

  tags       = { Name = "${local.prefix}-fgt-secondary" }
  depends_on = [aws_vpc_endpoint.s3, aws_s3_object.config, aws_s3_object.license]
}

#--- EIPs -----------------------------------------------------------------------------------------------
# Cluster EIP is allocated in the root module (both sites need each other's address). FortiOS moves it
# to the new master on failover, so ignore drift on the association.
resource "aws_eip_association" "cluster" {
  allocation_id        = var.cluster_eip_allocation_id
  network_interface_id = aws_network_interface.primary_port1.id
  depends_on           = [aws_internet_gateway.inspection, aws_instance.primary]
  lifecycle {
    ignore_changes = [network_interface_id, private_ip_address, instance_id]
  }
}

# EIPs on the HA management interface (port3), defined in config system ha: failover does not move them. The cluster EIP
# (port1) is the only EIP FortiOS reassigns. Port4 deliberately has no EIP.
resource "aws_eip" "mgmt" {
  count  = var.enable_fgt_management_eip ? 2 : 0
  domain = "vpc"
  tags   = { Name = "${local.prefix}-fgt-${count.index == 0 ? "primary" : "secondary"}-ha-mgmt-eip" }
}
resource "aws_eip_association" "mgmt_primary" {
  count                = var.enable_fgt_management_eip ? 1 : 0
  allocation_id        = aws_eip.mgmt[0].id
  network_interface_id = aws_network_interface.primary_port3.id
  depends_on           = [aws_instance.primary]
}
resource "aws_eip_association" "mgmt_secondary" {
  count                = var.enable_fgt_management_eip ? 1 : 0
  allocation_id        = aws_eip.mgmt[1].id
  network_interface_id = aws_network_interface.secondary_port3.id
  depends_on           = [aws_instance.secondary]
}
