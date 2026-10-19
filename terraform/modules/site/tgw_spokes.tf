#====================================================================================================
# TRANSIT GATEWAY + EAST/WEST SPOKE VPCs
#   The inspection VPC attachment is only the transport for the Connect (GRE) attachments: no route table
#   association, propagation or route uses it. Each spoke reaches the HA pair through its own Connect
#   attachment (see connect.tf), with its own TGW route tables.
# Spokes have no IGW; all egress and east-west traffic goes through the HA pair over GRE.
#====================================================================================================

resource "aws_ec2_transit_gateway" "this" {
  description                     = "${local.prefix} TGW"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  transit_gateway_cidr_blocks     = var.tgw_cidr_blocks
  tags                            = { Name = "${local.prefix}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  vpc_id                 = aws_vpc.inspection.id
  subnet_ids             = aws_subnet.tgw[*].id
  appliance_mode_support = "enable"
  # Transport for the Connect attachments only; it is deliberately not associated with any route table.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${local.prefix}-inspection-tgw-attachment" }
}

#--- Spoke VPCs (east + west) ----------------------------------------------------------------------
locals {
  spokes = {
    east = var.east_cidr
    west = var.west_cidr
  }
}

resource "aws_vpc" "spoke" {
  for_each             = local.spokes
  cidr_block           = each.value
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-${each.key}-vpc" }
}

# /26s: 0/1 = tgw az1/az2, 2/3 = workload az1/az2
resource "aws_subnet" "spoke_tgw" {
  for_each          = { for p in setproduct(keys(local.spokes), [0, 1]) : "${p[0]}-${p[1]}" => { spoke = p[0], az = p[1] } }
  vpc_id            = aws_vpc.spoke[each.value.spoke].id
  cidr_block        = cidrsubnet(local.spokes[each.value.spoke], 2, each.value.az)
  availability_zone = local.azs[each.value.az]
  tags              = { Name = "${local.prefix}-${each.value.spoke}-tgw-az${each.value.az + 1}-subnet" }
}
resource "aws_subnet" "spoke_workload" {
  for_each          = { for p in setproduct(keys(local.spokes), [0, 1]) : "${p[0]}-${p[1]}" => { spoke = p[0], az = p[1] } }
  vpc_id            = aws_vpc.spoke[each.value.spoke].id
  cidr_block        = cidrsubnet(local.spokes[each.value.spoke], 2, each.value.az + 2)
  availability_zone = local.azs[each.value.az]
  tags              = { Name = "${local.prefix}-${each.value.spoke}-workload-az${each.value.az + 1}-subnet" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each           = local.spokes
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.spoke[each.key].id
  subnet_ids         = [aws_subnet.spoke_tgw["${each.key}-0"].id, aws_subnet.spoke_tgw["${each.key}-1"].id]
  # Appliance mode keeps each flow on one AZ's path through the inspection VPC
  appliance_mode_support                          = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${local.prefix}-${each.key}-tgw-attachment" }
}
resource "aws_route_table" "spoke" {
  for_each = local.spokes
  vpc_id   = aws_vpc.spoke[each.key].id
  tags     = { Name = "${local.prefix}-${each.key}-rtb" }
}
resource "aws_route" "spoke_default" {
  for_each               = local.spokes
  route_table_id         = aws_route_table.spoke[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}
resource "aws_route_table_association" "spoke_workload" {
  for_each       = aws_subnet.spoke_workload
  subnet_id      = each.value.id
  route_table_id = aws_route_table.spoke[split("-", each.key)[0]].id
}
resource "aws_route_table_association" "spoke_tgw" {
  for_each       = aws_subnet.spoke_tgw
  subnet_id      = each.value.id
  route_table_id = aws_route_table.spoke[split("-", each.key)[0]].id
}

#--- Optional test instances (SSM, no public IP; egress goes through the HA pair) --------------------
data "aws_ssm_parameter" "al2023" {
  count = var.enable_spoke_instances ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "spoke_ssm" {
  count = var.enable_spoke_instances ? 1 : 0
  name  = "${local.prefix}-spoke-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}
resource "aws_iam_role_policy_attachment" "spoke_ssm" {
  count      = var.enable_spoke_instances ? 1 : 0
  role       = aws_iam_role.spoke_ssm[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "spoke_ssm" {
  count = var.enable_spoke_instances ? 1 : 0
  name  = "${local.prefix}-spoke-ssm-profile"
  role  = aws_iam_role.spoke_ssm[0].name
}

resource "aws_security_group" "spoke" {
  for_each    = local.spokes
  name        = "${local.prefix}-${each.key}-sg"
  description = "Spoke test instances: all from private ranges, SSH from anywhere (only reachable through the FortiGate VIPs), all egress"
  vpc_id      = aws_vpc.spoke[each.key].id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }
  # SSH VIPs are not source-NATed (the GRE inside addresses are not routable from the spokes), so the
  # instance sees the admin's public source address. The spokes have no IGW; access is gated by the FortiGate policy.
  ingress {
    description = "SSH via the FortiGate VIPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.prefix}-${each.key}-sg" }
}

resource "aws_instance" "spoke" {
  for_each               = var.enable_spoke_instances ? local.spokes : {}
  ami                    = data.aws_ssm_parameter.al2023[0].value
  instance_type          = var.spoke_instance_type
  subnet_id              = aws_subnet.spoke_workload["${each.key}-0"].id
  private_ip             = cidrhost(aws_subnet.spoke_workload["${each.key}-0"].cidr_block, var.spoke_host_ip)
  vpc_security_group_ids = [aws_security_group.spoke[each.key].id]
  key_name               = var.keypair
  iam_instance_profile   = aws_iam_instance_profile.spoke_ssm[0].name
  # Egress (SSM, package repos) only works once the HA pair is up and forwarding.
  depends_on = [aws_route.spoke_default, aws_ec2_transit_gateway_route_table_propagation.connect_to_spoke, aws_instance.secondary]
  tags       = { Name = "${local.prefix}-${each.key}-instance-az1" }
}
