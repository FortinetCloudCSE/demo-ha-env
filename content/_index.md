---
title: "Isolated Customer Traffic Across Two FortiGate FGCP HA Pairs in AWS"
linkTitle: "HA Demo Environment"
weight: 1
archetype: "home"
description: "Two FortiGate FGCP HA pairs, TGW Connect (GRE) to the spokes, and per-customer GRE tunnels inside an IPsec tunnel between the sites"
---

![Two FortiGate FGCP HA pairs joined by IPsec, with per-customer GRE isolation](demo-design.svg)

This documentation describes the **demo-ha-env** demo: a Terraform-built design in which two customers (**east** and **west**)
share one pair of FortiGates at each of two sites, yet their traffic stays separate end to end. Each customer has its own
GRE tunnel to the Transit Gateway and its own GRE tunnel, carried inside an IPsec tunnel, to the other site.

Each customer is isolated by its own GRE tunnels, its own **VRF** on the FortiGate, and firewall policy, with `skip-vrf-match` on the policies that leave the VRF. See [VRF Isolation](6_vrf_isolation/).
