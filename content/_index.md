---
title: "Isolated Customer Traffic Across Two FortiGate FGCP HA Pairs in AWS"
linkTitle: "HA Demo Environment"
weight: 1
archetype: "home"
description: "Two FortiGate FGCP HA pairs, TGW Connect (GRE) to the spokes, and per-customer GRE tunnels inside an IPsec tunnel between the sites"
---

<!-- TODO: replace with Lucidchart export (full design, both sites): demo-design.png -->
```
        Site A                                                              Site B
 ┌───────────────────────────────┐                          ┌───────────────────────────────┐
 │ east VPC ─┐                   │                          │                   ┌─ east VPC │
 │           ├─ TGW ══GRE══ FGCP │═══ IPsec ═══ GRE-x ═════│ FGCP ══GRE══ TGW ─┤           │
 │ west VPC ─┘  (Connect)   pair │  (gre-east-x, gre-west-x)│ pair  (Connect)   └─ west VPC │
 └───────────────────────────────┘                          └───────────────────────────────┘
                 │ port4 (multi-VPC ENI, no EIP)                 │ port4 (multi-VPC ENI, no EIP)
                 └──────────────┐                 ┌──────────────┘
                         Management VPC: FortiManager + FortiAnalyzer
```

This documentation describes the **demo-ha-env** demo: a Terraform-built design in which two customers (**east** and **west**)
share one pair of FortiGates at each of two sites, yet their traffic stays separate end to end. Each customer has its own
GRE tunnel to the Transit Gateway and its own GRE tunnel, carried inside an IPsec tunnel, to the other site.

It also records, in detail, why per-customer **VRFs** were tried and dropped. See [Why Not VRFs](6_why_not_vrfs/).
