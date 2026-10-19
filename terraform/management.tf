#====================================================================================================
# MANAGEMENT VPC (shared by both sites)
#   - own IGW, public subnets in AZ1/AZ2
#   - FortiManager + FortiAnalyzer (AMI chosen by version number, matched against the AMI name)
#   - receives the port4 ENI of every FortiGate in both HA pairs (multi-VPC ENI attachment)
# Not attached to either TGW: FortiGates reach it directly through port4.
#====================================================================================================

resource "aws_vpc" "management" {
  cidr_block           = var.vpc_cidr_management
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.prefix}-management-vpc" }
}

resource "aws_internet_gateway" "management" {
  vpc_id = aws_vpc.management.id
  tags   = { Name = "${local.prefix}-management-igw" }
}

resource "aws_subnet" "management_public_az1" {
  vpc_id                  = aws_vpc.management.id
  cidr_block              = cidrsubnet(var.vpc_cidr_management, 2, 0)
  availability_zone       = local.availability_zone_1
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-management-public-az1-subnet" }
}
resource "aws_subnet" "management_public_az2" {
  vpc_id                  = aws_vpc.management.id
  cidr_block              = cidrsubnet(var.vpc_cidr_management, 2, 1)
  availability_zone       = local.availability_zone_2
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.prefix}-management-public-az2-subnet" }
}

resource "aws_route_table" "management_public" {
  vpc_id = aws_vpc.management.id
  tags   = { Name = "${local.prefix}-management-public-rtb" }
}
resource "aws_route" "management_default" {
  route_table_id         = aws_route_table.management_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.management.id
}
resource "aws_route_table_association" "management_public_az1" {
  subnet_id      = aws_subnet.management_public_az1.id
  route_table_id = aws_route_table.management_public.id
}
resource "aws_route_table_association" "management_public_az2" {
  subnet_id      = aws_subnet.management_public_az2.id
  route_table_id = aws_route_table.management_public.id
}

#--- Security groups --------------------------------------------------------------------------------
# Applied to every FortiGate port4 ENI (SGs must live in the ENI's VPC, i.e. this one).
resource "aws_security_group" "fortigate_management" {
  name        = "${local.prefix}-fortigate-mgmt-sg"
  description = "FortiGate port4: FGFM only, from inside the management VPC (no EIP, no admin access)"
  vpc_id      = aws_vpc.management.id

  ingress {
    description = "FGFM (FortiManager to the FortiGate)"
    from_port   = 541
    to_port     = 541
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_management]
  }
  egress {
    description = "FortiGate to FortiManager and FortiAnalyzer inside the management VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr_management]
  }
  tags = { Name = "${local.prefix}-fortigate-mgmt-sg" }
}

resource "aws_security_group" "fortimanager" {
  count       = var.enable_fortimanager ? 1 : 0
  name        = "${local.prefix}-fortimanager-sg"
  description = "FortiManager"
  vpc_id      = aws_vpc.management.id

  ingress {
    description = "GUI/API"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "FGFM from the FortiGate port4 ENIs"
    from_port   = 541
    to_port     = 541
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_management]
  }
  ingress {
    description = "ICMP from inside the management VPC"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr_management]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.prefix}-fortimanager-sg" }
}

resource "aws_security_group" "fortianalyzer" {
  count       = var.enable_fortianalyzer ? 1 : 0
  name        = "${local.prefix}-fortianalyzer-sg"
  description = "FortiAnalyzer"
  vpc_id      = aws_vpc.management.id

  ingress {
    description = "GUI/API"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.management_cidr_sg
  }
  ingress {
    description = "OFTP log forwarding from FortiGates"
    from_port   = 514
    to_port     = 514
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_management]
  }
  ingress {
    description = "Syslog from FortiGates"
    from_port   = 514
    to_port     = 514
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr_management]
  }
  ingress {
    description = "ICMP from inside the management VPC"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr_management]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.prefix}-fortianalyzer-sg" }
}

#--- AMIs: matched on the version string inside the AMI name ----------------------------------------
data "aws_ami" "fortimanager" {
  count       = var.enable_fortimanager ? 1 : 0
  most_recent = true
  owners      = ["679593333241"] # Fortinet

  filter {
    name   = "name"
    values = ["FortiManager*VM64-AWS *(${var.fortimanager_os_version}*) GA*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "fortianalyzer" {
  count       = var.enable_fortianalyzer ? 1 : 0
  most_recent = true
  owners      = ["679593333241"] # Fortinet

  filter {
    name   = "name"
    values = ["FortiAnalyzer*VM64-AWS *(${var.fortianalyzer_os_version}*) GA*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#--- FortiManager / FortiAnalyzer -------------------------------------------------------------------
locals {
  # Static addresses so the FortiGate bootstrap config can reference them without depending on the instances.
  fortimanager_ip  = var.enable_fortimanager ? cidrhost(aws_subnet.management_public_az1.cidr_block, var.fortimanager_host_ip) : ""
  fortianalyzer_ip = var.enable_fortianalyzer ? cidrhost(aws_subnet.management_public_az1.cidr_block, var.fortianalyzer_host_ip) : ""

  management_az1_host_ips = concat(
    var.enable_fortimanager ? [var.fortimanager_host_ip] : [],
    var.enable_fortianalyzer ? [var.fortianalyzer_host_ip] : [],
    [for v in var.fortigate_mgmt_host_ips : v[0]],
  )
}

# Every pinned address in the management AZ1 subnet must be distinct (AZ2 only holds FortiGate port4 ENIs).
resource "terraform_data" "management_ip_check" {
  lifecycle {
    precondition {
      condition     = length(local.management_az1_host_ips) == length(distinct(local.management_az1_host_ips)) && min(local.management_az1_host_ips...) >= 4
      error_message = "Management AZ1 host numbers collide or fall in the AWS-reserved range (.0-.3): ${join(", ", local.management_az1_host_ips)}."
    }
  }
}

resource "aws_instance" "fortimanager" {
  count                  = var.enable_fortimanager ? 1 : 0
  ami                    = data.aws_ami.fortimanager[0].id
  instance_type          = var.fortimanager_instance_type
  availability_zone      = local.availability_zone_1
  subnet_id              = aws_subnet.management_public_az1.id
  private_ip             = local.fortimanager_ip
  vpc_security_group_ids = [aws_security_group.fortimanager[0].id]
  key_name               = var.keypair
  user_data = templatefile("${path.module}/config_templates/fmgr-userdata.tftpl", {
    fmg_license_file   = var.fortimanager_license_file
    fmg_vm_name        = var.fortimanager_vm_name
    fmg_admin_password = local.fortimanager_admin_password
  })
  tags = { Name = "${local.prefix}-fortimanager" }
}

resource "aws_instance" "fortianalyzer" {
  count                  = var.enable_fortianalyzer ? 1 : 0
  ami                    = data.aws_ami.fortianalyzer[0].id
  instance_type          = var.fortianalyzer_instance_type
  availability_zone      = local.availability_zone_1
  subnet_id              = aws_subnet.management_public_az1.id
  private_ip             = local.fortianalyzer_ip
  vpc_security_group_ids = [aws_security_group.fortianalyzer[0].id]
  key_name               = var.keypair
  user_data = templatefile("${path.module}/config_templates/faz-userdata.tftpl", {
    faz_license_file   = var.fortianalyzer_license_file
    faz_vm_name        = var.fortianalyzer_vm_name
    faz_admin_password = local.fortianalyzer_admin_password
  })
  tags = { Name = "${local.prefix}-fortianalyzer" }
}

resource "aws_eip" "fortimanager" {
  count      = var.enable_fortimanager && var.enable_fortimanager_public_ip ? 1 : 0
  domain     = "vpc"
  instance   = aws_instance.fortimanager[0].id
  tags       = { Name = "${local.prefix}-fortimanager-eip" }
  depends_on = [aws_internet_gateway.management]
}
resource "aws_eip" "fortianalyzer" {
  count      = var.enable_fortianalyzer && var.enable_fortianalyzer_public_ip ? 1 : 0
  domain     = "vpc"
  instance   = aws_instance.fortianalyzer[0].id
  tags       = { Name = "${local.prefix}-fortianalyzer-eip" }
  depends_on = [aws_internet_gateway.management]
}
