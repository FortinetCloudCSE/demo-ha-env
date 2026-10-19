---
title: "Alternatives"
chapter: false
menuTitle: "Alternatives"
weight: 64
---

## What the current design does instead

No VRFs. The customers are separated by their own tunnels, their own BGP prefix-lists, their own TGW route tables, and
per-customer firewall policy. See [Customer Isolation](../../3_solution_components/3_5_customer_isolation/).

That keeps internet egress and the SSH VIPs working, because every flow stays in one routing table. The limits are:
no overlapping customer address space, and a shared routing table.

## If customers need their own routing tables

The failure was a flow that has to cross from a customer VRF to port1. Any fix has to give each customer VRF its own way to
the internet that does not cross VRFs.

| Option | How it works | Cost |
|---|---|---|
| **A. A port per customer** | Add port5 (VRF 10) and port6 (VRF 20), each with its own subnet and EIP. NAT and VIPs for a customer use its own port. Every flow then stays inside one VRF. | Two more ENIs per FortiGate, two more EIPs per site, new subnets, and more EIPs to move on an HA failover |
| **B. A VDOM per customer** | Each customer is a separate VDOM with its own interfaces and policy. | Changes HA, FortiManager registration and the whole bootstrap template. Strongest isolation. |
| **C. No internet through the firewall** | Keep the VRFs and the per-customer tunnels, give the spokes SSM VPC endpoints for access and drop the VIPs. | The spokes lose general internet egress |

<!-- TODO: replace with Lucidchart export (option A): demo-vrf-port-per-customer.png -->
```
   Option A: one egress port per customer VRF

   VRF 10:  gre-east ─► [ policy ] ─► port5 (VRF 10) ─► EIP-east ─► internet
   VRF 20:  gre-west ─► [ policy ] ─► port6 (VRF 20) ─► EIP-west ─► internet
   VRF 0:   port1 (cluster EIP), IPsec underlay, port2 (GRE underlay), port3
```

**Recommendation if VRFs are required:** option A. Each customer would also get its own public address, which is often what
a multi-customer design wants anyway.

## What would stay the same

The tunnel structure in this design does not change under any of these options: a GRE tunnel per customer to the TGW, and a
GRE tunnel per customer inside the IPsec tunnel. Putting those interfaces into VRFs worked in the test. Only the egress and
the VIPs need something new.
