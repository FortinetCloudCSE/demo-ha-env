---
title: "Customer Isolation"
chapter: false
menuTitle: "Customer Isolation"
weight: 35
---

## Overview

East and west are isolated by **five independent controls**. Removing any one of them still leaves the others in place, which
is the point.

| Layer | What separates east from west |
|---|---|
| FortiGate VRFs | east is **VRF 10** and west is **VRF 20**: each customer's tunnels, BGP sessions, routes and sessions live in its own routing table |
| TGW route tables | each spoke has its own `spoke_rt` and `connect_rt`, so the east VPC only learns routes the east Connect peer advertises |
| BGP prefix-lists | each TGW peer pair is sent only its own customer's remote prefix (`pl-east-out`, `pl-west-out`) |
| Tunnels | `gre-east` / `gre-east-x` carry east only, `gre-west` / `gre-west-x` carry west only |
| Firewall policy | per-customer policies and a final logged `deny-east-west` |

## The policy table

| ID | Name | From | To | Action |
|---|---|---|---|---|
| 1 | `east-to-internet` | `gre-east` (local-east) | port1 | accept, NAT, `skip-vrf-match` |
| 2 | `west-to-internet` | `gre-west` (local-west) | port1 | accept, NAT, `skip-vrf-match` |
| 3 | `east-to-remote-east` | `gre-east` | `gre-east-x` | accept |
| 4 | `remote-east-to-east` | `gre-east-x` | `gre-east` | accept |
| 5 | `west-to-remote-west` | `gre-west` | `gre-west-x` | accept |
| 6 | `remote-west-to-west` | `gre-west-x` | `gre-west` | accept |
| 7 | `deny-east-west` | any GRE interface | any GRE interface | **deny, logged** |
| 8, 9 | `ipsec-tunnel-out`, `ipsec-tunnel-in` | the IPsec tunnel interface and port2 | the two tunnel endpoint addresses only | accept PING; carry nothing, they exist so FortiOS will negotiate the tunnel (see [Inter-Site GRE](../3_4_inter_site_gre/)) |
| 10+ | `ssh-to-<site>-<name>` | port1 | `gre-<customer>` | accept (VIPs), `skip-vrf-match` |

Policy 7 is not strictly required, because the implicit deny would drop the traffic anyway. It exists so an attempt to cross
shows up in the traffic log, which is useful in a demo.

## The VRFs

A VRF exists once an interface has `set vrf <n>`. The customer VRF is one value per customer in `modules/site/connect.tf`
(`customer_vrf = { east = 10, west = 20 }`), and the bootstrap template applies it to everything that belongs to that customer:

| Interface | VRF |
|---|---|
| `gre-east`, `gre-east-x` | 10 |
| `gre-west`, `gre-west-x` | 20 |
| port1 (public), port2 (TGW side), the IPsec interface | 0 (default), shared |
| port3 (HA), port4 (management VPC) | port4 is VRF 1, for FortiManager and FortiAnalyzer only |

The BGP neighbors for a customer join its VRF through their `interface` and `update-source` settings (a neighbor has no `vrf`
option). In `get router info bgp summary` the east neighbors appear under `VRF 10` and the west neighbors under `VRF 20`, and
nothing is left under the default VRF.

### The routes the template builds

Each VRF needs a few static routes, because a tunnel in a VRF looks up its outer destination in that VRF, and because internet
traffic has to cross to port1 and back. The route IDs below are the ones in `fgt-config.tpl`:

| ID | VRF | Destination | Exit | Why |
|---|---|---|---|---|
| 10 | 0 | the TGW CIDR | port2 | GRE underlay for the shared default VRF |
| 20, 21 | customer | the remote site's customer CIDR | `gre-<c>-x` | cross-site traffic stays in the customer's VRF |
| 30, 40 | customer | the TGW CIDR | port2 | the tunnel's outer destination, looked up in the customer's VRF |
| 50, 51 | customer | the remote tunnel address | the IPsec interface | underlay for `gre-<c>-x` |
| 60, 61 | customer | `0.0.0.0/0` | port1 | internet egress and VIP replies cross from the customer VRF to port1 |
| 70, 71 | 0 | the customer's local spoke CIDR | `gre-<c>` | the way back from port1 to the spokes |

Routes 30 to 71 are *leaked* routes: the exit interface is in a different VRF from the route, shown as `S D` in the routing
table.

### skip-vrf-match

Leaked routes make the routing lookup work, but a session is tied to the VRF of the interface its first packet arrived on. A
reply that arrives in a different VRF is dropped with `no session matched`. `set skip-vrf-match enable` on a firewall policy tells
the FortiGate to ignore the VRF when it matches the reply of a cross-VRF session. It is set on the policies that cross between a
customer VRF and port1: internet egress (1, 2) and the SSH VIPs (10 and up). The inter-site policies (3 to 6) stay inside one VRF
and do not need it. How it works is in [Cross-VRF Traffic](../../6_vrf_isolation/6_3_cross_vrf_traffic/).

To confirm it on a running pair, see [Verify and Troubleshoot](../../6_vrf_isolation/6_4_verify_and_troubleshoot/).

## What is deliberately not isolated

Both customers share:

- the physical firewalls and their CPU
- port1 and the cluster EIP, for internet egress (both are NATed to the same address)
- the policy table and the one FortiGate configuration

The VRFs separate routing tables and sessions. They do not give each customer a separate public address or a separate firewall.
If a customer needs those, see [Limits and Options](../../6_vrf_isolation/6_5_limits_and_options/).

## Overlapping address space

The demo uses non-overlapping CIDRs. VRFs make overlapping ranges possible in principle, but this was **not tested**, and the BGP
prefixes, TGW route tables and return routes all assume distinct ranges.
