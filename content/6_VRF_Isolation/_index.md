---
title: "VRF Isolation"
chapter: true
menuTitle: "VRF Isolation"
weight: 60
aliases:
  - /6_why_not_vrfs/
---

# VRF Isolation

Each customer gets its own VRF on the FortiGate: **east is VRF 10 and west is VRF 20**. This chapter records how that was
built, the failure found on the way, the one setting that fixes it, and the evidence. It was tested on a live pair
(FortiOS 8.0.1 build 0245), first by hand and then from the bootstrap template.

{{% notice info %}}
An earlier version of this chapter was called "Why Not VRFs". The first attempt failed and the VRFs were dropped. A
suggestion to use `skip-vrf-match` on the firewall policies then fixed it, and the design now uses VRFs. The failure is kept
here because it explains why the setting is needed.
{{% /notice %}}

## The short version

- Putting the **GRE tunnels into VRFs works**, including BGP inside each VRF. Each VRF has its own routing table.
- **Internet egress and the SSH VIPs fail by default.** Those flows must cross from a customer VRF to port1, which is in the
  default VRF. The packets are forwarded, but the **reply is dropped** with `no session matched`, because the session is
  created in one VRF and the reply arrives in the other.
- Leaking routes between VRFs with static routes is **necessary but not enough**. It answers the routing lookup, not the
  session lookup.
- **`set skip-vrf-match enable` on the firewall policy fixes it.** It tells the FortiGate to ignore the VRF when it matches
  the reply of a cross-VRF session. With it, egress and the VIPs work. Without it, they fail again. Both were tested.

## What was tested

| Flow | `skip-vrf-match` off | `skip-vrf-match` on |
|---|---|---|
| SSH VIP (port1 to a spoke through `gre-east`) | fails, `no session matched` | works |
| Internet egress (`gre-east` to port1) | times out, no reply | works |
| East to east across the sites | works (no VRF crossing) | not needed |
| West to west across the sites | works (no VRF crossing) | not needed |
| East to west, and east to the other site's west | blocked, as designed | |

## Pages in this chapter

| Page | Content |
|---|---|
| [Goal and Approach](6_1_goal_and_approach/) | What was being built and how the test was run |
| [What Worked](6_2_what_worked/) | VRF on GRE, BGP in a VRF, the underlay route |
| [The Failure and the Fix](6_3_why_it_fails/) | The two failing flows, the debug output, and `skip-vrf-match` |
| [Other Options](6_4_alternatives/) | What else would work, and when you would want it |

To check the VRFs on a running pair, see the VRF steps in [Validation](../5_validation/).

{{% notice info %}}
The `skip-vrf-match` result was observed on FortiOS 8.0.1 build 0245 only. Other builds were not tried.
{{% /notice %}}
