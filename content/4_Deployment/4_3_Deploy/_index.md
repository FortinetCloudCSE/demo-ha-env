---
title: "Deploy"
chapter: false
menuTitle: "Deploy"
weight: 43
---

## Run

```
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit first
terraform init
terraform plan -out plan.out
terraform apply plan.out
```

Expect a few hundred resources (a recent plan was 224 to add). The apply takes about 15 to 20 minutes, mostly the
Transit Gateway attachments, the Connect peers and the instances.

## What happens at first boot

Each FortiGate boots with a small user-data JSON (`bucket`, `region`, `config`, `license`). The unit reads its own
configuration from a private per-site S3 bucket, through its instance profile. An S3 gateway endpoint on the public route
table lets the secondary (no public address on port1) reach the bucket at first boot.

{{% notice info %}}
**Changing the template replaces the FortiGates.** `fgt-config.tpl` is part of the user-data, so editing it forces
replacement of the instances on the next apply, and any manual configuration on them is lost. Do not apply on top of a demo
that is in use.
{{% /notice %}}

## Destroying

```
terraform destroy
```

## After the apply

1. `terraform output` for the cluster EIPs and the per-unit management EIPs
2. Log in to a primary on its port3 (HA-management) EIP (HTTPS or SSH, user `admin`)
3. Run the checks on the [Validation](../../5_validation/) page
