---
title: "FAQs and Troubleshooting"
menuTitle: "FAQs"
weight: 80
---

## Why does `skip-vrf-match` appear on some firewall policies?

Each customer is in its own VRF, but internet egress and the SSH VIPs have to cross to port1 in the default VRF. Without the option
the reply arrives in a different VRF from the one that created the session and is dropped with `no session matched`. It is set
on the egress and VIP policies only. See [Cross-VRF Traffic](../6_vrf_isolation/6_3_cross_vrf_traffic/).

## Why PAYG and not BYOL or FortiFlex?

On FortiOS 8.0.1 build 0245 the BYOL and FortiFlex units stayed at `License Status: Pending`. See
[Licensing](../3_solution_components/3_6_licensing/).

## The GUI on the management EIP hangs and never loads

Check the license. A unit whose license is `Pending` accepts the TCP connection to 443 but sends no TLS reply. With a valid
license the same GUI answers.

## The secondary cannot form a cluster, or the cluster splits

The secondary's heartbeat must leave through port3. Check that the ha-mgmt security group allows the whole inspection CIDR.
In an earlier test the secondary's heartbeat left port1 with a port1 source address; rebooting the secondary re-joined it.

## Why is port4 not the HA management interface?

FortiOS hides the HA management interface from the list of selectable source interfaces for FortiGuard, FortiManager and
FortiAnalyzer (`entry not found in datasource`), so those services could not be pointed at it. Port3 is the HA management
interface, as in the FGCP reference, and port4 is an ordinary interface in VRF 1 for FortiManager and FortiAnalyzer. See
[Management](../3_solution_components/3_2_management/).

## Why is there no EC2 API VPC endpoint?

Port3 is the HA management interface, in a public subnet with an EIP. The EC2 API calls that move the cluster EIP leave
through it and reach the public API directly, which the FGCP reference calls critical. An endpoint is only needed when the
units have no EIPs (`enable_fgt_management_eip = false`).

## The IPsec tunnel never comes up and no IKE packets are sent

Run `diagnose debug application ike -1`, `diagnose debug enable`, then `diagnose vpn tunnel up <tunnel>`. If it says
`ignoring request to establish IPsec SA, no policy configured`, no firewall policy references the tunnel interface. Policies
8 and 9 supply that. See [Inter-Site GRE](../3_solution_components/3_4_inter_site_gre/).

## BGP neighbors will not establish

Walk the layers: `diagnose sniffer packet port2 'proto 47'` for GRE in both directions, then the route to the TGW GRE
address (it must go via port2, not the port1 default), then the Connect peer's `peer_address` (the primary's port2 IP).

## The secondary has no management EIP

Check `terraform output` and the EIP association on the unit's port3 ENI in the console. The EIPs are on the HA management
ports (port3) and failover should not move them. If one moves, report it.

## I changed the template and my FortiGates were replaced

The config template is part of the instance user-data. Changing it replaces the instances. Do not apply over a demo in use.

## `terraform plan` says ExpiredToken but I just logged in

Stale exported `AWS_*` variables override the SSO profile. `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`.

## Useful commands

```
get system ha status
diagnose sys ha checksum cluster
get router info bgp summary
get router info routing-table all
diagnose vpn ike gateway list
diagnose netlink interface list <gre interface>
diagnose sniffer packet <interface> '<filter>' 4 0 l
```

{{% notice info %}}
FortiOS `grep` has no `-E`. Use plain patterns or `grep -f`. `execute sleep` does not exist.
{{% /notice %}}
