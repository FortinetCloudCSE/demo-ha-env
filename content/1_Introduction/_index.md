---
title: "Introduction"
menuTitle: "Introduction"
weight: 10
---

## Welcome

This repository (`demo-ha-env`) is a customer demo built with Terraform. It answers one question: **how do you inspect two customers' traffic on a
shared pair of FortiGates in AWS and keep the customers isolated from each other, within a site and across sites?**

The design uses:

- **FortiGate FGCP active-passive HA pairs** in two Availability Zones, one pair per site
- **AWS Transit Gateway (TGW) Connect** (GRE with eBGP) between each spoke VPC and the primary FortiGate
- **IPsec between the sites**, with one **GRE tunnel per customer inside it**
- **A shared management VPC** with FortiManager and FortiAnalyzer; each FortiGate has a port4 in it (no EIP) for FortiManager and FortiAnalyzer, and its own HA-management interface (port3, with an EIP) for GUI and SSH
- **A VRF per customer, plus firewall policy, for isolation** (see [VRF Isolation](../6_vrf_isolation/) for how it works and what it needs)

## Who this is for

Engineers who need to build or explain a multi-customer inspection design on FortiGate in AWS, and who want to know which
parts were verified on a running unit and which were not.

{{% notice warning %}}
This is demo code, not a production reference. The inter-site GRE tunnels in particular are new and unverified on a unit.
Each page says what has and has not been proven.
{{% /notice %}}

## What you will find here

| Section | What it covers |
|---|---|
| [Overview](../2_overview/) | The topology, addressing and traffic flows |
| [Solution Components](../3_solution_components/) | Each building block: HA, management, TGW Connect, inter-site GRE, isolation, licensing |
| [Deployment](../4_deployment/) | Prerequisites, variables and the apply |
| [Validation](../5_validation/) | The commands that prove each layer works |
| [VRF Isolation](../6_vrf_isolation/) | How GRE tunnels, VRFs and policy with `skip-vrf-match` isolate the customers, and how to verify it |
| [Use Cases](../7_usecases/) | SSH VIPs, internet egress, cross-site traffic, an isolation test |
| [FAQs](../8_faqs/) | Troubleshooting |
| [What We Learned](../9_what_we_learned/) | Why the management interfaces are laid out the way they are, and what failed before |
