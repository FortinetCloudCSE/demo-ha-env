#====================================================================================================
# GENERAL
#====================================================================================================
variable "aws_region" {
  description = "AWS region (both sites and the management VPC must share it: multi-VPC ENIs are same-region/same-AZ)"
  type        = string
}
variable "availability_zone_1" {
  description = "AZ suffix for the primary FortiGate and AZ1 subnets (e.g. a)"
  type        = string
}
variable "availability_zone_2" {
  description = "AZ suffix for the secondary FortiGate and AZ2 subnets (e.g. b)"
  type        = string
}
variable "cp" {
  description = "Customer prefix applied to all resource names"
  type        = string
}
variable "env" {
  description = "Environment name applied to all resource names"
  type        = string
}
variable "keypair" {
  description = "Existing EC2 key pair name"
  type        = string
}
variable "management_cidr_sg" {
  description = "CIDRs allowed to reach FortiGate port4, FortiManager and FortiAnalyzer"
  type        = list(string)
}
variable "ssh_admin_sources" {
  description = "FortiGate address object name => source CIDR allowed through the port1 SSH forwards on both sites"
  type        = map(string)
  default     = {}
}
variable "site_a_ssh_forwards" {
  description = "Site A port1 VIPs forwarding a public TCP port to SSH (22) on a spoke instance; spoke (east or west) selects the target, that spoke instance pinned IP (spoke_host_ip)"
  type = list(object({
    name  = string
    port  = number
    spoke = string
  }))
  default = []
}
variable "site_b_ssh_forwards" {
  description = "Site B port1 VIPs forwarding a public TCP port to SSH (22) on a spoke instance; spoke (east or west) selects the target, that spoke instance pinned IP (spoke_host_ip)"
  type = list(object({
    name  = string
    port  = number
    spoke = string
  }))
  default = []
}
variable "additional_tags" {
  description = "Extra tags merged into the provider default_tags"
  type        = map(string)
  default     = {}
}

#====================================================================================================
# SITES
#====================================================================================================
variable "site_a" {
  description = "Site A addressing and licensing. inspection_cidr is a /21 (eight /24 subnets), the spoke CIDRs are /24s; none may overlap each other or the management VPC."
  type = object({
    inspection_cidr           = string
    east_cidr                 = string
    west_cidr                 = string
    primary_license_file      = optional(string, "")
    secondary_license_file    = optional(string, "")
    primary_fortiflex_token   = optional(string, "")
    secondary_fortiflex_token = optional(string, "")
  })
  default = {
    inspection_cidr = "10.1.0.0/21"
    east_cidr       = "10.1.10.0/24"
    west_cidr       = "10.1.20.0/24"
  }
}
variable "site_b" {
  description = "Site B addressing and licensing."
  type = object({
    inspection_cidr           = string
    east_cidr                 = string
    west_cidr                 = string
    primary_license_file      = optional(string, "")
    secondary_license_file    = optional(string, "")
    primary_fortiflex_token   = optional(string, "")
    secondary_fortiflex_token = optional(string, "")
  })
  default = {
    inspection_cidr = "10.2.0.0/21"
    east_cidr       = "10.2.10.0/24"
    west_cidr       = "10.2.20.0/24"
  }
}
variable "demo_password" {
  description = "One password for every demo secret: FortiGate admin, HA, IPsec PSK, FortiManager and FortiAnalyzer admin. The per-secret variables below override it when set."
  type        = string
  sensitive   = true
}
variable "ipsec_psk" {
  description = "Override for the site-to-site IPsec pre-shared key (default: demo_password)"
  type        = string
  default     = ""
  sensitive   = true
}

#====================================================================================================
# FORTIGATE
#====================================================================================================
variable "fortigate_instance_type" {
  description = "Instance type for all four FortiGates (needs >= 4 ENIs)"
  type        = string
  default     = "c5n.xlarge"
}
variable "fortios_version" {
  description = "FortiOS version matched against the FortiGate AMI name, e.g. 7.4.5"
  type        = string
  default     = "7.4.5"
}
variable "license_type" {
  description = "payg, byol or fortiflex"
  type        = string
  default     = "payg"
  validation {
    condition     = contains(["payg", "byol", "fortiflex"], var.license_type)
    error_message = "license_type must be payg, byol or fortiflex."
  }
}
variable "fortigate_admin_password" {
  description = "Override for the FortiGate admin password (default: demo_password)"
  type        = string
  default     = ""
  sensitive   = true
}
variable "ha_password" {
  description = "Override for the FGCP HA password, same for both pairs (default: demo_password)"
  type        = string
  default     = ""
  sensitive   = true
}
variable "enable_fgt_management_eip" {
  description = "Put an EIP on each FortiGate's port3 (HA management) for direct GUI/SSH; it is also the unit's own path to the public EC2 API"
  type        = bool
  default     = true
}

#====================================================================================================
# MANAGEMENT VPC, FORTIMANAGER, FORTIANALYZER
#====================================================================================================
variable "vpc_cidr_management" {
  description = "Management VPC CIDR (a /24 is expected)"
  type        = string
  default     = "10.99.0.0/24"
}

variable "enable_fortimanager" {
  type    = bool
  default = true
}
variable "enable_fortimanager_public_ip" {
  type    = bool
  default = true
}
variable "fortimanager_instance_type" {
  type    = string
  default = "m5.xlarge"
}
variable "fortimanager_os_version" {
  description = "FortiManager version matched against the AMI name, e.g. 7.6.1"
  type        = string
  default     = "7.6.1"
}
variable "fortigate_mgmt_host_ips" {
  description = "Host numbers of each FortiGate port4 in the management AZ1 / AZ2 subnets, per site: [primary, secondary]. Must not collide with the FortiManager / FortiAnalyzer host numbers or each other within a subnet."
  type        = map(list(number))
  default = {
    site_a = [20, 20]
    site_b = [21, 21]
  }
}
variable "fortimanager_host_ip" {
  description = "Host number within the management AZ1 subnet"
  type        = number
  default     = 14
}
variable "fortimanager_license_file" {
  description = "Path to FortiManager license (empty = PAYG)"
  type        = string
  default     = ""
}
variable "fortimanager_vm_name" {
  type    = string
  default = ""
}
variable "fortimanager_admin_password" {
  description = "Override for the FortiManager admin password (default: demo_password)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_fortianalyzer" {
  type    = bool
  default = true
}
variable "enable_fortianalyzer_public_ip" {
  type    = bool
  default = true
}
variable "fortianalyzer_instance_type" {
  type    = string
  default = "m5.xlarge"
}
variable "fortianalyzer_os_version" {
  description = "FortiAnalyzer version matched against the AMI name, e.g. 7.6.1"
  type        = string
  default     = "7.6.1"
}
variable "fortianalyzer_host_ip" {
  description = "Host number within the management AZ1 subnet"
  type        = number
  default     = 13
}
variable "fortianalyzer_license_file" {
  description = "Path to FortiAnalyzer license (empty = PAYG)"
  type        = string
  default     = ""
}
variable "fortianalyzer_vm_name" {
  type    = string
  default = ""
}
variable "fortianalyzer_admin_password" {
  description = "Override for the FortiAnalyzer admin password (default: demo_password)"
  type        = string
  default     = ""
  sensitive   = true
}

#====================================================================================================
# TEST INSTANCES
#====================================================================================================
variable "enable_spoke_instances" {
  description = "One SSM-managed Linux test instance per spoke VPC (4 total)"
  type        = bool
  default     = true
}
variable "tgw_cidr_blocks" {
  description = "Per site TGW CIDR block for the GRE addresses of the Connect peers; must not overlap any VPC"
  type        = map(string)
  default = {
    site_a = "10.254.1.0/24"
    site_b = "10.254.2.0/24"
  }
}
variable "spoke_host_ip" {
  description = "Host number of the spoke test instances within their workload subnet; also the SSH VIP target. AWS reserves .0-.3"
  type        = number
  default     = 4
  validation {
    condition     = var.spoke_host_ip >= 4
    error_message = "spoke_host_ip must be 4 or higher (AWS reserves .0-.3 in every subnet)."
  }
}
variable "spoke_instance_type" {
  type    = string
  default = "t3.micro"
}

#--- FortiFlex (read by scripts/apply_fortiflex.py; Terraform itself does not use them) ---------------------
variable "fortiflex_username" {
  description = "FortiFlex API username"
  type        = string
  default     = ""
}
variable "fortiflex_password" {
  description = "FortiFlex API password"
  type        = string
  default     = ""
  sensitive   = true
}
variable "fortigate_sns" {
  description = "FortiFlex entitlement serial numbers per site: [primary, secondary]"
  type        = map(list(string))
  default     = {}
}
variable "fortimanager_sn" {
  description = "FortiFlex entitlement serial number for FortiManager"
  type        = string
  default     = ""
}
variable "fortianalyzer_sn" {
  description = "FortiFlex entitlement serial number for FortiAnalyzer"
  type        = string
  default     = ""
}
