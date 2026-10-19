---
title: "Solution Components"
chapter: true
menuTitle: "Solution Components"
weight: 30
---

The design is built from six components. Each page explains what the component does, how the Terraform configures it, and
what has been verified on a running unit.

## What you will learn

- **Inspection VPC and HA**: the FGCP pair, its interfaces and the heartbeat
- **Management**: port3 as the combined HA management and heartbeat interface (with an EIP), and port4 (no EIP, VRF 1) into the management VPC
- **TGW Connect (GRE)**: how each spoke reaches the primary FortiGate with eBGP
- **Inter-site GRE**: one GRE tunnel per customer inside the IPsec tunnel
- **Customer isolation**: how policy, BGP prefix-lists and TGW route tables keep the customers apart
- **Licensing**: why the demo uses pay-as-you-go

Select a component from the navigation menu.
