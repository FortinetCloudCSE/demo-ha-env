terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = merge({
      Environment = var.env
      Terraform   = "true"
      Project     = "${var.cp}-dual-site-fgcp"
    }, var.additional_tags)
  }
}

locals {
  availability_zone_1 = "${var.aws_region}${var.availability_zone_1}"
  availability_zone_2 = "${var.aws_region}${var.availability_zone_2}"
  prefix              = "${var.cp}-${var.env}"
}

#====================================================================================================
# FORTIGATE AMI -- looked up by FortiOS version against the AMI name, same approach as
# existing_vpc_resources does for FortiManager/FortiAnalyzer.
#   BYOL : "FortiGate-VM64-AWS build2463 (7.4.5) GA-..."
#   PAYG : "FortiGate-VM64-AWSONDEMAND build2463 (7.4.5) GA-..."
# The space after "AWS" keeps the BYOL pattern from also matching the ONDEMAND images.
#====================================================================================================
data "aws_ami" "fortigate" {
  most_recent = true
  owners      = ["679593333241"] # Fortinet

  filter {
    name   = "name"
    values = [var.license_type == "payg" ? "FortiGate-VM64-AWSONDEMAND build*(${var.fortios_version}*)*" : "FortiGate-VM64-AWS build*(${var.fortios_version}*)*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  fortigate_admin_password     = var.fortigate_admin_password != "" ? var.fortigate_admin_password : var.demo_password
  ha_password                  = var.ha_password != "" ? var.ha_password : var.demo_password
  ipsec_psk                    = var.ipsec_psk != "" ? var.ipsec_psk : var.demo_password
  fortimanager_admin_password  = var.fortimanager_admin_password != "" ? var.fortimanager_admin_password : var.demo_password
  fortianalyzer_admin_password = var.fortianalyzer_admin_password != "" ? var.fortianalyzer_admin_password : var.demo_password
}
