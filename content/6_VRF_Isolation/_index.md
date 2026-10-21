---
title: "VRF Isolation"
chapter: true
menuTitle: "VRF Isolation"
weight: 60
---

# VRF Isolation

Two customers share one pair of FortiGates at each site. Their traffic must stay separate end to end, and each customer
still needs internet egress and inbound access to its own backend instances. This chapter shows how the design gets there, in
layers:

1. **A GRE tunnel per customer**, to the Transit Gateway and to the other site, so each customer has its own path.
2. **A VRF per customer** on the FortiGate (east 10, west 20), so each customer has its own routing table and its own sessions.
3. **Firewall policy** that says who may talk to whom, with a logged deny between the customers.
4. **`skip-vrf-match` on the policies that leave the customer VRF** (internet egress and the SSH VIPs), so replies that come back
   through the shared port find their session.

Tested on FortiOS 8.0.1 build 0245, on both sites.

## What was verified

| Flow | Result |
|---|---|
| East to east and west to west across the sites | works, and stays inside one VRF |
| East to west, on either site | blocked |
| Internet egress from a spoke | works, returns the site's cluster EIP |
| SSH to a spoke through a VIP on the cluster EIP | works |
| Egress and the VIP with `skip-vrf-match` removed | fail, `no session matched`; they work again when it is restored |

## Pages in this chapter

| Page | Content |
|---|---|
| [Use Case and Design](6_1_use_case_and_design/) | What the customers need, and how the four layers build up to it |
| [Building It](6_2_building_it/) | The configuration, step by step, with what each step is for |
| [Cross-VRF Traffic](6_3_cross_vrf_traffic/) | How egress and the VIPs cross between a customer VRF and port1, and what `skip-vrf-match` does |
| [Verify and Troubleshoot](6_4_verify_and_troubleshoot/) | The commands that prove it works, how to read the debug output, and what a problem looks like |
| [Limits and Options](6_5_limits_and_options/) | What the design does not give you, and what to do if you need more |
