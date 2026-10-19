---
title: "Customer Isolation"
chapter: false
menuTitle: "Customer Isolation"
weight: 35
---

## Overview

East and west are isolated by **four independent controls**. Removing any one of them still leaves the others in place, which
is the point.

| Layer | What separates east from west |
|---|---|
| TGW route tables | each spoke has its own `spoke_rt` and `connect_rt`, so the east VPC only learns routes the east Connect peer advertises |
| BGP prefix-lists | each TGW peer pair is sent only its own customer's remote prefix (`pl-east-out`, `pl-west-out`) |
| Tunnels | `gre-east` / `gre-east-x` carry east only, `gre-west` / `gre-west-x` carry west only |
| Firewall policy | per-customer policies and a final logged `deny-east-west` |

## The policy table

| ID | Name | From | To | Action |
|---|---|---|---|---|
| 1 | `east-to-internet` | `gre-east` (local-east) | port1 | accept, NAT |
| 2 | `west-to-internet` | `gre-west` (local-west) | port1 | accept, NAT |
| 3 | `east-to-remote-east` | `gre-east` | `gre-east-x` | accept |
| 4 | `remote-east-to-east` | `gre-east-x` | `gre-east` | accept |
| 5 | `west-to-remote-west` | `gre-west` | `gre-west-x` | accept |
| 6 | `remote-west-to-west` | `gre-west-x` | `gre-west` | accept |
| 7 | `deny-east-west` | any GRE interface | any GRE interface | **deny, logged** |
| 8, 9 | `ipsec-tunnel-out`, `ipsec-tunnel-in` | the IPsec tunnel interface and port2 | the two tunnel endpoint addresses only | accept PING; carry nothing, they exist so FortiOS will negotiate the tunnel (see [Inter-Site GRE](../3_4_inter_site_gre/)) |
| 10+ | `ssh-to-<site>-<name>` | port1 | `gre-<customer>` | accept (VIPs) |

Policy 7 is not strictly required, because the implicit deny would drop the traffic anyway. It exists so an attempt to cross
shows up in the traffic log, which is useful in a demo.

## What is deliberately not isolated

Both customers share:

- the physical firewalls and their CPU
- port1 and the cluster EIP, for internet egress (both are NATed to the same address)
- the one FortiGate routing table

This is policy-based separation, not a separation of routing tables. If a customer needs its own routing table, see
[Why Not VRFs](../../6_why_not_vrfs/) for what was tried and what it would take.

## Overlapping address space

The demo uses non-overlapping CIDRs. Because there is a single routing table, two customers **cannot** use the same address
range behind the same firewall pair. That would need VRFs (or VDOMs) and an egress path for each customer.
