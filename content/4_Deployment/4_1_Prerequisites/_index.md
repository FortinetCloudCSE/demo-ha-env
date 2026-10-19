---
title: "Prerequisites"
chapter: false
menuTitle: "Prerequisites"
weight: 41
---

## You need

- Terraform
- An AWS login (`aws sso login`) with permissions across EC2, VPC, Transit Gateway, S3, IAM and Elastic IP
- An existing EC2 key pair in the target region (`keypair`)
- Your public IP, for `management_cidr_sg` and `ssh_admin_sources`
- Subscriptions for the FortiGate, FortiManager and FortiAnalyzer AMIs in the AWS Marketplace

{{% notice warning %}}
**Stale environment credentials.** If your shell exports `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` or
`AWS_SESSION_TOKEN` from an earlier session, they override a fresh SSO login and Terraform fails with `ExpiredToken`.
Unset them (`unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`) and keep `AWS_PROFILE`.
{{% /notice %}}

## Where to run Terraform

All Terraform commands run from the `terraform/` directory of the repository. `scripts/` and `generate_network_diagram.sh`
stay at the repository root and change into `terraform/` themselves.

## Check the AMI exists

The FortiGate AMI is looked up by version string, so confirm the version exists in your region:

```
aws ec2 describe-images --owners 679593333241 --region us-west-2 \
  --filters "Name=name,Values=FortiGate-VM64-AWSONDEMAND build*(8.0*)*" \
  --query 'Images[].Name'
```

## Note on SASE and VPN clients

A SASE or VPN client on your laptop changes the source address that AWS and the FortiGates see. If you cannot reach the
GUI, SSH or the VIPs, check that the address you appear from is in `management_cidr_sg` and `ssh_admin_sources`.
