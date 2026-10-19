---
title: "Why It Fails"
chapter: false
menuTitle: "Why It Fails"
weight: 63
---

## The symptom

With the GRE tunnels in VRF 10 and 20, BGP up, and every route lookup correct (see [What Worked](../6_2_what_worked/)), two things
stopped working:

1. **Internet egress from the spoke instances.** The instances' connections to the AWS Systems Manager endpoints (TCP 443)
   never completed. The SSM agent kept retransmitting its SYN.
2. **The SSH VIPs on the cluster EIP.** `ssh -p 2222 <cluster EIP>` timed out.

Both flows cross between a customer VRF and port1, which is in the default VRF.

## Flow 1: the VIP (default VRF to VRF 10 and back)

```
admin ──SYN──► port1 (VRF 0) ──DNAT──► 10.1.10.132:22 ──► gre-east (VRF 10) ──► TGW ──► instance
admin ◄──────  port1 ◄──────────────── ??? ◄────────────── gre-east ◄────────────────── SYN-ACK
```

**The forward direction worked.** `diagnose debug flow` on the SYN from the admin's address:

```
vd-root:0 received a packet(proto=6, 203.0.113.10:61972->10.1.0.4:2222) ... from port1. flag [S]
allocate a new session-00001ce1
find DNAT: IP-10.1.10.132, port-22
DNAT 10.1.0.4:2222->10.1.10.132:22
find a route: ... gw-169.254.6.2 via gre-east
Allowed by Policy-5:
```

The session was created in `vd-root:0`, the default VRF.

A sniffer on `gre-east` showed the instance answering, once per retry, about a millisecond later:

```
gre-east out 203.0.113.10.62027 -> 10.1.10.132.22: syn
gre-east in  10.1.10.132.22 -> 203.0.113.10.62027: syn ack
gre-east out 203.0.113.10.62027 -> 10.1.10.132.22: syn        (client retransmits)
gre-east in  10.1.10.132.22 -> 203.0.113.10.62027: syn ack
```

So the SYN-ACK reached the firewall, but the client never received it. The flow debug on the reply packet shows why:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:22->203.0.113.10:62073)
    ... from gre-east. flag [S.], seq 2824026180, ack 1591977016
find a route: flag=00000000 gw-10.1.0.1 via port1
no session matched
```

The reply is received as **`vd-root:10`**, the VRF 10 context. The session it belongs to exists in **`vd-root:0`**. FortiOS says
`no session matched` and drops it.

## Flow 2: internet egress (VRF 10 to default VRF and back)

```
instance ──SYN──► gre-east (VRF 10) ──SNAT──► port1 (VRF 0) ──► AWS endpoint
instance ◄─────── ??? ◄──────────────────────── port1 ◄────────── SYN-ACK
```

The same thing in the other direction. The forward debug:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:44656->44.248.100.235:443) ... from gre-east. flag [S]
allocate a new session-00001af7
find a route: flag=00000000 gw-10.1.0.1 via port1
find SNAT: IP-10.1.0.4(from IPPOOL), port-44656
Allowed by Policy-1: SNAT
```

The session was created in `vd-root:10`. On port1 the SYN left (`10.1.0.4.59732 -> 44.248.101.226.443: syn`) and the
SYN-ACK came back a millisecond later:

```
port1 -- 10.1.0.4.59732 -> 44.248.101.226.443: syn
port1 -- 44.248.101.226.443 -> 10.1.0.4.59732: syn ack
```

The SYN-ACK arrives in the default VRF, the session is in VRF 10, and the instance never sees it. It keeps retransmitting.
(These excerpts are separate captures of the same behavior, from different retries.)

{{% notice warning %}}
**Evidence gap.** For flow 1 the reply-side debug printed `no session matched`. For flow 2 the reply was seen arriving on
port1 and never reaching the instance, but the reply-side `diagnose debug flow` was not captured. Flow 2 is treated as the
same mechanism because it is the mirror image of flow 1 and fails in the same way, not because the drop message was seen.
{{% /notice %}}

## The mechanism

<!-- TODO: replace with Lucidchart export (session created in one VRF, reply in another): demo-vrf-session.png -->
```
   First packet                                       Reply packet
   ────────────                                       ────────────
   arrives on gre-east                                arrives on port1
   ingress VRF = 10                                   ingress VRF = 0
        │                                                  │
        ▼                                                  ▼
   route lookup in VRF 10        (works: leaked          session lookup in VRF 0
   default via port1              static route)               │
        │                                                  no session matched
        ▼                                                  │
   policy lookup, SNAT                                     ▼
        │                                                 DROP
        ▼
   session created in VRF 10
   (original: gre-east / VRF 10,
    reply: expected back from port1)
```

Both flows share the pattern:

| | Flow 1 (VIP) | Flow 2 (egress) |
|---|---|---|
| Session created in | VRF 0 (packet arrived on port1) | VRF 10 (packet arrived on gre-east) |
| Reply arrives in | VRF 10 (on gre-east) | VRF 0 (on port1) |
| Result | `no session matched` (seen) | reply never reaches the instance (drop message not captured) |

The first packet works because the **routing lookup** is satisfied by a leaked static route. The reply fails because the
**session lookup** takes the VRF of the interface the packet arrived on, and does not find the session that the first
packet created in the other VRF.

## Why leaked static routes cannot fix it

The leaked routes (`S D` in the routing table) change what the routing table returns. They do not change which VRF a packet
belongs to. A packet's VRF comes from the interface it arrives on. A session is created in that context. Nothing in the
leak makes the reply arrive in the original VRF, so the reply and the original packet never meet in one session.

Everything that stays inside one VRF is fine. For example, `gre-east` to `gre-east-x`, both in VRF 10, is a single-VRF flow.
It is only the flows that must cross to the default VRF (port1) that fail.

## What was not tested

- **BGP route leaking** (`config router bgp` / `config vrf` / `leak-target`). This also leaks *routes*. The failure above is in
  the session lookup, not the routing table, so there is no reason to expect it to behave differently. It was not tested.
- **Other FortiOS builds.** Everything here is FortiOS 8.0.1 build 0245.
- **Whether this is documented behavior.** The explanation above fits the evidence but was not confirmed against Fortinet
  documentation. A Fortinet case citing the two debug excerpts would settle it.

## What the failure cost

Nothing permanent. The VRF changes were made by hand on a unit that was destroyed afterward, and none of it reached the
Terraform. To undo it on a unit: set `vrf 0` on the GRE interfaces, delete the leaked static routes, and `unset interface` /
`unset update-source` on the BGP neighbors.
