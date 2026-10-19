---
title: "Deployment"
chapter: true
menuTitle: "Deployment"
weight: 40
---

# Deployment

The whole design is one Terraform root module (in the `terraform/` directory) with a reusable `modules/site` for each site. This section covers the
prerequisites, the variables, and the apply.

## Repository layout

| Path | Purpose |
|---|---|
| `terraform/main.tf`, `terraform/management.tf` | provider, FortiGate AMI lookup, management VPC, security groups, FortiManager and FortiAnalyzer |
| `terraform/sites.tf` | the cluster EIPs and the two `modules/site` instances |
| `terraform/modules/site/` | one site: inspection VPC, TGW and spokes (`tgw_spokes.tf`), TGW Connect and the inter-site addressing (`connect.tf`), FortiGates (`fortigate.tf`) |
| `terraform/modules/site/templates/fgt-config.tpl` | the FortiGate bootstrap: HA, IPsec, GRE, BGP, policies, FortiManager and FortiAnalyzer registration |
| `terraform/modules/site/bootstrap.tf` | S3 bootstrap: bucket, per-unit config, S3 gateway endpoint, user-data |
| `terraform/templates/ssh-forwards.tpl` | per-site SSH VIPs |
| `generate_network_diagram.sh` | writes `diagram/network_diagram.{svg,md}` |

## Pages in this section

- **Prerequisites**: tools, AWS access, key pair
- **Variables**: what to set in `terraform.tfvars`
- **Deploy**: plan, apply, and what to expect
