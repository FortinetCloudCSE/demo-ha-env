---
title: "Use Case and Design"
chapter: false
menuTitle: "Use Case and Design"
weight: 61
---

## What the customers need

- **Isolation.** A customer's traffic, routes and sessions never meet another customer's, on the shared FortiGates and across the
  IPsec tunnel between the sites.
- **Egress.** Each customer's instances reach the internet through the firewall.
- **Ingress.** An administrator reaches a customer's backend instance from the internet through a VIP and NAT on the cluster EIP.
- **Same customer, both sites.** East at site A reaches east at site B, and west reaches west.

## How the design builds up

Each layer adds something the layer below does not give.

| Layer | What it gives | What it does not give |
|---|---|---|
| **GRE tunnel per customer** (`gre-east`, `gre-west` to the TGW, `gre-east-x`, `gre-west-x` to the other site) | each customer has its own path and its own BGP sessions, so a customer's prefixes travel only in its own tunnels | the FortiGate still has one routing table and one session table |
| **A VRF per customer** (east 10, west 20) | each customer has its own routing table and its own sessions, so one customer's route can never match another's traffic | no rule about what a customer may reach |
| **Firewall policy** | per-customer policies for egress, same-customer traffic across the sites and the VIPs, and a final logged `deny-east-west` | a way for a reply to return through a different VRF than the one that created the session |
| **`skip-vrf-match`** on the egress and VIP policies | the reply of a flow that crosses between a customer VRF and port1 finds its session | nothing else; it is set only where a flow needs it |

![The three VRFs on a FortiGate: default VRF 0, VRF 10 for east and VRF 20 for west](demo-vrf-topology.svg)

## Where VRFs sit on the FortiGate

There is no VRF object in FortiOS. A VRF exists once an interface has `set vrf <n>`.

| Interface | VRF |
|---|---|
| `gre-east`, `gre-east-x` | 10 |
| `gre-west`, `gre-west-x` | 20 |
| port1 (public, cluster EIP), port2 (TGW side), the IPsec interface | 0, the default VRF, shared |
| port4 (management VPC) | 1, for FortiManager and FortiAnalyzer only |

Two flows have to leave the customer VRF: **internet egress** (customer VRF to port1) and the **SSH VIPs** (port1 to the customer
VRF). Everything else stays inside one VRF. Those two flows are why the design needs a few leaked routes and `skip-vrf-match`,
described in [Building It](../6_2_building_it/) and [Cross-VRF Traffic](../6_3_cross_vrf_traffic/).

## In Terraform

The VRF is one value per customer in `terraform/modules/site/connect.tf`, `customer_vrf = { east = 10, west = 20 }`. It is passed to
the bootstrap template as `vrf` on each customer's tunnel entries, so the interfaces, BGP neighbors, routes and policies all pick it up
from one place.
