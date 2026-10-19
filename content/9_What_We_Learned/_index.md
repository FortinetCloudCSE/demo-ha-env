---
title: "What We Learned"
chapter: true
menuTitle: "What We Learned"
weight: 90
---

# What We Learned

The management design went through four iterations before it settled. Each earlier one failed for a reason that is not obvious
from the documentation, so the reasons are recorded here. Everything below was observed on FortiOS 8.0.1 (build 0245); the
page says where a cause was established and where it was only observed.

## The management layout in one paragraph

**Port3** is the HA management interface, defined in `config system ha`, and it also carries the heartbeat and config sync. It
sits in a public subnet and has an EIP on each unit. **Port4** is an ordinary multi-VPC ENI in the management VPC, in VRF 1 and
`dedicated-to management`, with **no EIP** and only `fgfm` allowed. It carries FortiManager and FortiAnalyzer traffic and nothing
else. FortiGuard uses the defaults.

## 1. An EIP on a management interface outside `config system ha` gets moved on failover

**What we saw.** In the first versions of the design, port3 was the HA management interface with no public path, and a separate
management ENI (port4, in the management VPC) carried an EIP for GUI and SSH. After a failover, and during rebuilds, the EIPs
on the management ENIs moved between the units. At one point a secondary showed no management EIP at all while the other unit
held two. The administrator's observation was "HA shouldn't move management EIPs."

**What the reference says.** The FGCP reference describes exactly one EIP movement: the *cluster* EIP, assigned to the primary IP
of the data-plane port (port1), is reassigned to the new master, and routes that target the old master are updated. The IAM role
exists to "reassign cluster EIPs assigned to primary IPs assigned to the data plane ENIs". The reference puts the unit's own EIP
on the HA management interface, which it describes as the unit's independent path.

**What fixed it.** Moving the per-unit EIP onto the interface defined in `config system ha` (`ha-mgmt-interface`, port3). Failover
no longer moves it. Port4 has no EIP at all, so there is nothing on it to move.

{{% notice warning %}}
**The mechanism was never established.** We did not find out *why* FortiOS moved the EIPs on a management ENI that was outside
the HA configuration. The explanation that fits the evidence is that FortiOS only treats an interface as a unit-owned management
port when it is named in `config system ha`. The IAM policy that FortiOS runs under allows `ec2:AssociateAddress` and
`ec2:DisassociateAddress` on every resource, so scoping it down is a possible hardening step; it was not tried.
{{% /notice %}}

**Rule of thumb.** If a FortiGate needs a per-unit EIP for administration, put it on the HA management interface. Do not put it on
a separate management ENI.

## 2. The HA management interface cannot be chosen as the source interface for FortiGuard and friends

**What we saw.** With port4 as the HA management interface, the bootstrap lines that pointed the services at it silently
disappeared. On the running unit:

| Setting | What the template asked for | What the unit had |
|---|---|---|
| `system central-management` | `interface-select-method specify`, `interface port4` | `type fortimanager` and `fmg` only; `interface-select-method` was `auto` |
| `log fortianalyzer setting` | status, server, `specify`, `port4` | **empty** |
| `system fortiguard` | `specify`, `port4` | defaults |

With the method on `auto`, the FortiGate resolved the FortiManager address through its normal routing table and sent it out
port1 on the default route. The management VPC is private, so it never arrived (a ping to `10.99.0.14` failed, and a sniffer on
port4 saw no traffic).

**The confirmed error.** Typed by hand on the unit:

```
config system fortiguard
    set interface-select-method specify
    set interface port4
entry not found in datasource
value parse error before 'port4'
```

FortiOS does not offer the HA management interface in the list of interfaces a service may use as its source. This was
confirmed by hand for `system fortiguard`. The same two lines were dropped at bootstrap for `central-management` and
`log fortianalyzer setting`, which is consistent with the same limitation, but those two were not each tried by hand.

{{% notice info %}}
**An HA management interface is also kept out of the main routing table.** An early attempt to reach the peer's heartbeat
address through a static route via port3 was accepted by the CLI but never installed. The reserved management interface has its
own gateway (`ha-mgmt-interface`) and is not part of normal routing.
{{% /notice %}}

**What this means for licensing.** FortiGuard cannot be pointed at the HA management interface, yet all four PAYG units validated
their license with the default FortiGuard settings, including the secondary, which has no EIP on port1. The evident explanation
is that the unit uses the HA management interface for its own outbound services when no other path exists. That was inferred
from the result, not observed directly.

## 3. Why port3 is the HA management interface and port4 is `dedicated-to management` for FortiManager and FortiAnalyzer only

Each iteration, and what ended it:

| # | Layout | What went wrong |
|---|---|---|
| 1 | port3 = HA management with no public path; port4 in VRF 1, `dedicated-to management`, with an EIP | The management EIPs moved around on failover (section 1). The secondary's heartbeat left port1 and split the cluster. |
| 2 | port4 = HA management interface, with an EIP | FortiManager, FortiAnalyzer and FortiGuard could not use it as a source interface (section 2). Registration failed. |
| 3 | considered: VPC peering or a TGW attachment from the management VPC to each inspection VPC | Would work, with a route out port2. Not built: it adds routing, and it drops the requirement that every FortiGate has a dedicated management interface in the management VPC. |
| 4 | **port3 = HA management with an EIP (the FGCP reference); port4 = `dedicated-to management`, VRF 1, no EIP, `fgfm` only** | The current design. |

**Why each piece is the way it is**

- **Port3 as the HA management interface, with an EIP, in a public subnet.** This is the FGCP reference design. It gives each
  unit, including the secondary, its own GUI and SSH address, and its own path to the public EC2 API, which the reference calls
  critical for failing over AWS SDN. Because the EIP is on the interface defined in `config system ha`, failover does not move it.
- **Port4 as an ordinary interface, not the HA management interface.** Section 2: FortiManager and FortiAnalyzer can only use an
  interface that FortiOS lets you select, and the HA management interface is not one of them.
- **Port4 with no EIP.** It has no internet role, so there is nothing for failover to move (section 1). Administration goes through
  port3.
- **`dedicated-to management` and VRF 1 on port4.** It keeps the management VPC traffic out of the data-plane routing table and
  preserves the requirement of a dedicated management interface in the management VPC. The traffic is generated and received by
  the FortiGate itself, so no flow crosses between VRFs, which is the case that failed in [Why Not VRFs](../6_why_not_vrfs/).
- **`allowaccess fgfm` only.** Port4 does one job. HTTPS, SSH and ping are not needed there, and the security group on the ENI
  allows only TCP 541 from the management VPC.
- **FortiGuard left on the defaults.** Port4 has no internet path, and the units validated without any FortiGuard interface
  setting.
- **`dedicated-to management` is the last stanza in the bootstrap.** FortiOS prompts to reboot when it is set, which aborts the
  init script, so the template ends with the port4 stanza and a `yend` line that answers the prompt. See
  [Management](../3_solution_components/3_2_management/).

## 4. Route leaking between VRFs is not session leaking

The first customer-isolation design put east in VRF 10 and west in VRF 20. It was tried by hand on a running unit and dropped.
The full test, with the debug output, is in [Why Not VRFs](../6_why_not_vrfs/). The short version:

**What worked.** A VRF on a GRE interface (`set vrf 10`), and a BGP neighbor inside that VRF. Each VRF learned only its own
customer's spoke prefix, so the routing tables separated cleanly.

**What broke, and how the leaked routes behaved.** Two flows must cross between a customer VRF and port1, which stays in the
default VRF: internet egress from the spokes, and the SSH VIPs. A static route can name a VRF, with an exit interface in another VRF,
and those leaked routes installed cleanly (`S D` in the routing table). Every route lookup then returned the right answer. The
first packet of each flow went through. The reply was dropped:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:22->...) from gre-east. flag [S.]
find a route: ... via port1
no session matched
```

The session was created in `vd-root:0` (the VRF of the interface the first packet arrived on). The reply arrived as
`vd-root:10`. FortiOS looks up a session in the VRF of the interface the packet arrives on, so it never found the session the
first packet had created in the other VRF. Leaking a route changes what the routing table returns. It does not change which VRF
a packet belongs to.

**Side effects on the firewall that you would not expect**
- **GRE underlay.** Moving a GRE interface into a VRF made FortiOS look up the tunnel's *outer* destination in that VRF. The route
  to the TGW lived only in the default VRF, so every transmit failed (the interface's `txe` counter climbed) and BGP stayed in
  `Active`. A leaked static route to the TGW CIDR in each VRF fixed it.
- **BGP.** A neighbor has no `vrf` option. It joins a VRF only through its `interface` (and `update-source`) setting.
  `get router info bgp summary vrf 10` does not exist on this build.
- **Debugging.** `diagnose debug flow` prints the VRF context of each packet (`vd-root:0` or `vd-root:10`). That is what exposed
  the problem. The sniffer showed the reply arriving, so the traffic looked healthy from outside.

**Scope.** This is an observation on FortiOS 8.0.1 build 0245, not a documented rule. BGP route leaking (`config vrf`,
`leak-target`) was not tried; it leaks routes, the same layer as the static leaks, so there is no reason to expect different session
behavior. Flows that stay inside one VRF are not affected, which is why the management VRF on port4 is fine (see section 3).

## Other lessons that live elsewhere

| Lesson | Where |
|---|---|
| Per-customer VRFs break internet egress and the SSH VIPs, because a session is tied to the VRF it was created in | [Why Not VRFs](../6_why_not_vrfs/) |
| An outbound BGP prefix-list also filters the default route from `capability-default-originate` ("default not sent") | [TGW Connect (GRE)](../3_solution_components/3_3_tgw_connect_gre/) |
| FortiOS will not negotiate a route-based IPsec tunnel unless a firewall policy references the tunnel interface | [Inter-Site GRE](../3_solution_components/3_4_inter_site_gre/) |
| BYOL and FortiFlex licenses stayed `Pending` on 8.0.1 while PAYG validated at once | [Licensing](../3_solution_components/3_6_licensing/) |
