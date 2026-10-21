---
title: "The Failure and the Fix"
chapter: false
menuTitle: "The Failure and the Fix"
weight: 63
---

## The symptom

With the GRE tunnels in VRF 10 and 20, BGP up, and every route lookup correct (see [What Worked](../6_2_what_worked/)), two things
stopped working **until `skip-vrf-match` was set on the firewall policies** (see [The fix](#the-fix) below):

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
vd-root:0 received a packet(proto=6, x.x.x.x:61972->10.1.0.4:2222) ... from port1. flag [S]
allocate a new session-00001ce1
find DNAT: IP-10.1.10.132, port-22
DNAT 10.1.0.4:2222->10.1.10.132:22
find a route: ... gw-169.254.6.2 via gre-east
Allowed by Policy-5:
```

The session was created in `vd-root:0`, the default VRF.

A sniffer on `gre-east` showed the instance answering, once per retry, about a millisecond later:

```
gre-east out x.x.x.x.62027 -> 10.1.10.132.22: syn
gre-east in  10.1.10.132.22 -> x.x.x.x.62027: syn ack
gre-east out x.x.x.x.62027 -> 10.1.10.132.22: syn        (client retransmits)
gre-east in  10.1.10.132.22 -> x.x.x.x.62027: syn ack
```

So the SYN-ACK reached the firewall, but the client never received it. The flow debug on the reply packet shows why:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:22->x.x.x.x:62073)
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

![A session created in one VRF is not found by a reply in another VRF](demo-vrf-session.svg)

Both flows share the pattern:

| | Flow 1 (VIP) | Flow 2 (egress) |
|---|---|---|
| Session created in | VRF 0 (packet arrived on port1) | VRF 10 (packet arrived on gre-east) |
| Reply arrives in | VRF 10 (on gre-east) | VRF 0 (on port1) |
| Result | `no session matched` (seen) | reply never reaches the instance (drop message not captured) |

The first packet works because the **routing lookup** is satisfied by a leaked static route. The reply fails because the
**session lookup** takes the VRF of the interface the packet arrived on, and does not find the session that the first
packet created in the other VRF.

## Why leaked static routes are not enough

The leaked routes (`S D` in the routing table) change what the routing table returns. They do not change which VRF a packet
belongs to. A packet's VRF comes from the interface it arrives on. A session is created in that context, and by default the
reply is looked up in the VRF of the interface *it* arrives on. Nothing in the leak makes the reply arrive in the original VRF,
so the reply and the original packet never meet in one session.

Everything that stays inside one VRF is fine. For example, `gre-east` to `gre-east-x`, both in VRF 10, is a single-VRF flow.
Only the flows that cross to the default VRF (port1) need the fix.

## The fix

FortiOS 8.0.1 has a firewall policy option, `skip-vrf-match`. It tells the FortiGate to ignore the VRF when it matches the reply
direction of a cross-VRF session, so the reply finds the session the first packet created.

```
config firewall policy
    edit 1                              # east-to-internet
        set skip-vrf-match enable
    next
    edit 10                             # ssh-to-site-a-east (the VIP policy)
        set skip-vrf-match enable
    next
end
```

It goes on the policies whose flows cross between a customer VRF and port1: the internet egress policies (1 and 2) and the SSH
VIP policies (10 and up). The inter-site policies (3 to 6) stay inside one VRF and do not need it.

### Evidence that it is the cause

The same flow was run with the option on and then off, and `diagnose debug flow` and the session table were captured each time.

**VIP, option on.** The session carries a `skip_vrf` flag, and the reply is matched:

```
session info: proto=6 proto_state=01 duration=14 expire=3588 timeout=3600 refresh_dir=both skip_vrf ...
orgin->sink: org pre->post, reply pre->post dev=3->15/15->3 gwy=169.254.6.2/10.1.0.1
hook=pre  dir=org   act=dnat x.x.x.x:49936->10.1.0.4:2222(10.1.10.132:22)
hook=post dir=reply act=snat 10.1.10.132:22->x.x.x.x:49936(10.1.0.4:2222)
misc=0 policy_id=10 ... vd=0
```

The forward direction leaves through `gre-east` and the reply returns through the port1 gateway (`gwy=169.254.6.2/10.1.0.1`):
two interfaces, two VRFs, one session.

**VIP, option off.** The SYN-ACK from the instance arrives on `gre-east` in VRF 10 and is dropped, over and over as it retransmits:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:22->x.x.x.x:50021) ... from gre-east. flag [S.]
find a route: flag=00000000 gw-10.1.0.1 via port1
no session matched
```

**Egress, option on.** The instance's connection is allowed by policy 1, translated to the port1 address, and the reply arrives in
VRF 0 and finds the session:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:55926->44.254.14.214:443) ... from gre-east
Allowed by Policy-1: SNAT
SNAT 10.1.10.132->10.1.0.4:55926
vd-root:0 received a packet(proto=6, 44.254.14.214:443->10.1.0.4:55926) ... from port1
Find an existing session, id-000004e4, reply direction
DNAT 10.1.0.4:55926->10.1.10.132:55926
```

**Egress, option off.** From the east spoke, `curl https://ifconfig.me` returned nothing. The debug shows the SYN allowed by
`Policy-1`, SNATed and sent out port1, then retransmitted several times with no reply ever delivered back to the spoke.

{{% notice warning %}}
**Evidence gap.** With the option off, the egress debug shows the SYN going out and retransmitting but does not print the explicit
`no session matched` for the reply. The debug filter was `addr` of the spoke, and the reply arrives addressed to the port1
address, so the filter hid it. The VIP case prints it. Egress is treated as the same mechanism because it fails only when the
option is off and works when it is on. The [Validation](../../5_validation/) page shows a filter that does capture it.
{{% /notice %}}

### Results

| Flow | Option off | Option on |
|---|---|---|
| SSH VIP | `no session matched`, SSH hangs | works, session shows `skip_vrf` |
| Internet egress | no reply delivered, curl returns nothing | works, returns the cluster EIP |

## What was not tested

- **BGP route leaking** (`config router bgp` / `config vrf` / `leak-target`). This also leaks *routes*, and the failure is in
  the session lookup, so it was not expected to help and was not tried.
- **Other FortiOS builds.** Everything here is FortiOS 8.0.1 build 0245.
- **Failover.** The behavior after the secondary takes over was not tested.
