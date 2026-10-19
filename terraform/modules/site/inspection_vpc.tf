#====================================================================================================
# INSPECTION VPC
#   eight equal subnets, /24 with a /21 inspection_cidr (index into cidrsubnet(inspection_cidr, 3, n)):
#     0/1 public az1/az2 (port1)   2/3 private az1/az2 (port2)
#     4/5 ha-mgmt az1/az2 (port3, public: EIP)  6/7 tgw az1/az2 (TGW attachment)
#====================================================================================================

locals {
  prefix = "${var.cp}-${var.env}-${var.site_name}"
  azs    = [var.availability_zone_1, var.availability_zone_2]

  public_cidrs  = [for i in [0, 1] : cidrsubnet(var.inspection_cidr, 3, i)]
  private_cidrs = [for i in [2, 3] : cidrsubnet(var.inspection_cidr, 3, i)]
  ha_cidrs      = [for i in [4, 5] : cidrsubnet(var.inspection_cidr, 3, i)]
  tgw_cidrs     = [for i in [6, 7] : cidrsubnet(var.inspection_cidr, 3, i)]

  local_spoke_cidrs = [var.east_cidr, var.west_cidr]
}

resource "aws_vpc" "inspection" {
  cidr_block           = var.inspection_cidr
  enable_dns_support   = true # keeps the AWS resolver (169.254.169.253) available to the FortiGates
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-inspection-vpc" }
}

resource "aws_internet_gateway" "inspection" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${local.prefix}-inspection-igw" }
}

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-inspection-public-az${count.index + 1}-subnet" }
}
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-inspection-private-az${count.index + 1}-subnet" }
}
resource "aws_subnet" "ha_mgmt" {
  count             = 2
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.ha_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-ha-mgmt-az${count.index + 1}-subnet" }
}
resource "aws_subnet" "tgw" {
  count             = 2
  vpc_id            = aws_vpc.inspection.id
  cidr_block        = local.tgw_cidrs[count.index]
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.prefix}-inspection-tgw-az${count.index + 1}-subnet" }
}

#--- Route tables -----------------------------------------------------------------------------------

# Public (port1): default to the IGW. IPsec to the peer's cluster EIP leaves here.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${local.prefix}-inspection-public-rtb" }
}
resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.inspection.id
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private (port2): everything that lives south of the TGW goes back via the TGW.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${local.prefix}-inspection-private-rtb" }
}
# GRE packets from port2 to the TGW side of the Connect peers go to the TGW (via the transport attachment)
resource "aws_route" "private_to_tgw_cidr" {
  for_each               = toset(var.tgw_cidr_blocks)
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = each.value
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.inspection]
}
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# HA management (port3): public, like the FGCP reference. Each unit has an EIP here for GUI/SSH and its own path to the
# public EC2 API (needed to fail over AWS SDN). Heartbeat and sync stay on the private addresses.
resource "aws_route_table" "ha_mgmt" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${local.prefix}-ha-mgmt-rtb" }
}
resource "aws_route" "ha_mgmt_default" {
  route_table_id         = aws_route_table.ha_mgmt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.inspection.id
}
resource "aws_route_table_association" "ha_mgmt" {
  count          = 2
  subnet_id      = aws_subnet.ha_mgmt[count.index].id
  route_table_id = aws_route_table.ha_mgmt.id
}

# TGW attachment subnets (transport only): local routes. Data no longer enters the VPC through these ENIs; it
# arrives as GRE on port2 from the TGW address.
resource "aws_route_table" "tgw" {
  vpc_id = aws_vpc.inspection.id
  tags   = { Name = "${local.prefix}-inspection-tgw-rtb" }
}
resource "aws_route_table_association" "tgw" {
  count          = 2
  subnet_id      = aws_subnet.tgw[count.index].id
  route_table_id = aws_route_table.tgw.id
}

#--- No EC2 API endpoint: port3 (the HA management interface) is in a public subnet with an EIP and reaches the public
# EC2 API directly, as in the FGCP reference. An endpoint is only needed when the units have no EIP.
