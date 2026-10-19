---
title: "Why Not VRFs"
chapter: true
menuTitle: "Why Not VRFs"
weight: 60
---

# Why Not VRFs

The first design for customer isolation put **east in VRF 10 and west in VRF 20**. It was tested by hand on a running
FortiGate (site A primary, FortiOS 8.0.1 build 0245) and dropped. This chapter records what was tried, what worked, the exact
point where it failed, the evidence, and what it would take to make VRFs work.

## The short version

- Putting the **GRE tunnels into VRFs works**, including BGP inside each VRF. The routing tables separate cleanly.
- **Internet egress and the SSH VIPs break.** Those flows must cross from a customer VRF to port1, which is in the default VRF.
- The packets are forwarded, but the **reply is dropped** with `no session matched`. The firewall session is created in one VRF,
  and the reply arrives in the other.
- Leaking routes between VRFs with static routes does not fix this, because it only solves the routing lookup, not the session lookup.

## Pages in this chapter

| Page | Content |
|---|---|
| [Goal and Approach](6_1_goal_and_approach/) | What was being built and how the test was run |
| [What Worked](6_2_what_worked/) | VRF on GRE, BGP in a VRF, the underlay route |
| [Why It Fails](6_3_why_it_fails/) | The two failing flows, with the debug output |
| [Alternatives](6_4_alternatives/) | What would work, and what each costs |

{{% notice info %}}
The conclusion about sessions comes from the debug evidence on this build. It is not taken from Fortinet documentation, which
the author did not find a statement of. Treat it as an observed behavior and confirm it with Fortinet before relying on it
in a design review.
{{% /notice %}}
