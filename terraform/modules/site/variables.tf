#====================================================================================================
# SITE MODULE INPUTS
# One "site" = inspection VPC + FGCP HA pair + TGW + east/west spoke VPCs.
#====================================================================================================

variable "site_name" {
  description = "Short site label used in resource names (e.g. site-a)"
  type        = string
}
variable "cp" { type = string }
variable "env" { type = string }
variable "aws_region" { type = string }
variable "availability_zone_1" {
  description = "Full AZ name for the primary FortiGate (e.g. us-west-2a)"
  type        = string
}
variable "availability_zone_2" {
  description = "Full AZ name for the secondary FortiGate (e.g. us-west-2b)"
  type        = string
}

#--- Addressing -------------------------------------------------------------------------------------
variable "inspection_cidr" {
  description = "Inspection VPC CIDR (a /21 is expected; it is carved into eight equal subnets, /24 each)"
  type        = string
}
variable "east_cidr" {
  description = "East spoke VPC CIDR (a /24 is expected)"
  type        = string
}
variable "west_cidr" {
  description = "West spoke VPC CIDR (a /24 is expected)"
  type        = string
}
variable "remote_spoke_cidrs" {
  description = "Spoke CIDRs at the OTHER site, reached over the IPsec tunnel"
  type        = list(string)
}
variable "remote_east_cidr" {
  description = "East spoke CIDR at the OTHER site (reached through gre-east-x)"
  type        = string
}
variable "remote_west_cidr" {
  description = "West spoke CIDR at the OTHER site (reached through gre-west-x)"
  type        = string
}
variable "site_index" {
  description = "1 for the site that takes the first address of every inter-site GRE /30, 2 for the other"
  type        = number
  validation {
    condition     = contains([1, 2], var.site_index)
    error_message = "site_index must be 1 or 2."
  }
}

#--- IPsec ------------------------------------------------------------------------------------------
variable "tunnel_name" {
  description = "Name of the IPsec phase1/phase2 interface (max 15 chars)"
  type        = string
}
variable "peer_public_ip" {
  description = "Cluster EIP of the peer HA pair"
  type        = string
}
variable "public_ingress_cidrs" {
  description = "Sources allowed to reach port1 (all protocols); access is then controlled by FortiGate policy"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
variable "extra_config" {
  description = "Site-specific FortiOS CLI inserted into the bootstrap before FMG/FAZ and the final port4 stanza"
  type        = string
  default     = ""
}
variable "ipsec_psk" {
  type      = string
  sensitive = true
}

#--- Cluster EIP (allocated by the root module so both sites can reference each other) -------------
variable "cluster_eip_allocation_id" {
  type = string
}

#--- Management VPC ---------------------------------------------------------------------------------
variable "management_vpc_cidr" { type = string }
variable "management_cidr_sg" {
  description = "Admin source CIDRs allowed to reach the port3 (HA management) GUI and SSH"
  type        = list(string)
}
variable "management_subnet_az1_id" { type = string }
variable "management_subnet_az2_id" { type = string }
variable "management_subnet_az1_cidr" { type = string }
variable "management_subnet_az2_cidr" { type = string }
variable "management_sg_id" {
  description = "Security group (in the management VPC) applied to the port4 ENIs: FGFM only"
  type        = string
}
variable "data_host_ip" {
  description = "Host number of the port1, port2 and port3 IPs in their subnets; pinned on the ENIs, FortiOS gets them over DHCP. AWS reserves .0-.3"
  type        = number
  default     = 4
}
variable "mgmt_host_ips" {
  description = "Host numbers of the port4 IPs in the management AZ1 / AZ2 subnets: [primary, secondary]"
  type        = list(number)
  validation {
    condition     = length(var.mgmt_host_ips) == 2
    error_message = "mgmt_host_ips needs exactly two entries: [primary, secondary]."
  }
}
variable "enable_fgt_management_eip" {
  description = "Attach an EIP to each FortiGate port4 (management VPC) for direct GUI/SSH access"
  type        = bool
  default     = true
}
variable "fortimanager_ip" {
  description = "Private IP of FortiManager (empty = not registered)"
  type        = string
  default     = ""
}
variable "fortianalyzer_ip" {
  description = "Private IP of FortiAnalyzer (empty = not logged to)"
  type        = string
  default     = ""
}

#--- FortiGate --------------------------------------------------------------------------------------
variable "keypair" { type = string }
variable "fortigate_instance_type" { type = string }
variable "fortigate_ami_id" { type = string }
variable "fortigate_admin_password" {
  type      = string
  sensitive = true
}
variable "ha_group_name" { type = string }
variable "ha_password" {
  type      = string
  sensitive = true
}
variable "license_type" {
  description = "payg, byol or fortiflex"
  type        = string
}
variable "primary_license_file" {
  type    = string
  default = ""
}
variable "secondary_license_file" {
  type    = string
  default = ""
}
variable "primary_fortiflex_token" {
  type      = string
  default   = ""
  sensitive = true
}
variable "secondary_fortiflex_token" {
  type      = string
  default   = ""
  sensitive = true
}

#--- Test instances ---------------------------------------------------------------------------------
variable "enable_spoke_instances" {
  description = "Create a small SSM-managed Linux test instance in each spoke VPC AZ1 subnet"
  type        = bool
  default     = true
}
variable "spoke_host_ip" {
  description = "Host number of the spoke test instances within their workload subnet (AWS reserves .0-.3)"
  type        = number
  default     = 4
}
variable "spoke_instance_type" {
  type    = string
  default = "t3.micro"
}

#--- TGW Connect (GRE) to the spokes ---------------------------------------------------------------
variable "tgw_cidr_blocks" {
  description = "Transit gateway CIDR block for the GRE addresses of the Connect peers; must not overlap any VPC"
  type        = list(string)
}
variable "fortigate_bgp_asn" {
  description = "BGP ASN of the FortiGates toward the TGW Connect peers (must differ from the TGW ASN, 64512)"
  type        = number
  default     = 65001
}
