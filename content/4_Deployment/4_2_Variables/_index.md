---
title: "Variables"
chapter: false
menuTitle: "Variables"
weight: 42
---

In the `terraform/` directory, copy `terraform.tfvars.example` to `terraform.tfvars` and edit. `terraform.tfvars`, state, licenses and FortiGate config
backups are excluded by `.gitignore`.

## Required

| Variable | Example | Notes |
|---|---|---|
| `aws_region` | `us-west-2` | single account and region |
| `availability_zone_1`, `availability_zone_2` | `a`, `b` | |
| `cp`, `env` | `acme`, `demo` | resource-name prefix |
| `keypair` | `my-keypair` | must already exist |
| `management_cidr_sg` | `["x.x.x.x/32"]` | who may reach the FortiGate port3 (HA-management) GUI and SSH |
| `site_a`, `site_b` | see below | non-overlapping CIDRs |
| `demo_password` | | one password for every demo secret |

```hcl
site_a = {
  inspection_cidr = "10.1.0.0/21"
  east_cidr       = "10.1.10.0/24"
  west_cidr       = "10.1.20.0/24"
}
site_b = {
  inspection_cidr = "10.2.0.0/21"
  east_cidr       = "10.2.10.0/24"
  west_cidr       = "10.2.20.0/24"
}
```

## FortiGate

| Variable | Example | Notes |
|---|---|---|
| `fortigate_instance_type` | `c5n.xlarge` | |
| `fortios_version` | `8.0` | matched against the AMI name; `8.0` resolves to 8.0.1 |
| `license_type` | `payg` | use `payg` (see [Licensing](../../3_solution_components/3_6_licensing/)) |
| `enable_fgt_management_eip` | `true` | an EIP on each port3 (HA management); keep it on unless the EC2 API endpoint is used |
| `fortigate_mgmt_host_ips` | `{ site_a = [20, 20], site_b = [21, 21] }` | host numbers of the port4 ENIs in the management subnets (no EIP) |
| `tgw_cidr_blocks` | `{ site_a = "10.254.1.0/24", site_b = "10.254.2.0/24" }` | TGW GRE address blocks; must not overlap any VPC |

## Management VPC

| Variable | Example |
|---|---|
| `vpc_cidr_management` | `10.99.0.0/24` |
| `enable_fortimanager`, `enable_fortianalyzer` | `true` |
| `fortimanager_host_ip`, `fortianalyzer_host_ip` | `14`, `13` |
| `fortimanager_os_version`, `fortianalyzer_os_version` | `7.6.7` |
| `fortimanager_license_file`, `fortianalyzer_license_file` | path to a `.lic`, or `""` |

A `terraform_data.management_ip_check` resource fails the plan if any pinned management address collides.

## Spokes and SSH forwards

```hcl
enable_spoke_instances = true
spoke_host_ip          = 4          # host in the AZ1 workload subnet

site_a_ssh_forwards = [
  { name = "east", port = 2222, spoke = "east" },
  { name = "west", port = 2223, spoke = "west" },
]
```

The forward target is computed with `cidrhost()`, not read from the instances, so it does not depend on them.

## Not a variable

The customer names, the GRE keys (10, 20) and the inter-site address ranges (169.254.100.0/30, 169.254.10.0/30,
169.254.20.0/30) are fixed in `terraform/modules/site/connect.tf`. Changing them is a code change.
