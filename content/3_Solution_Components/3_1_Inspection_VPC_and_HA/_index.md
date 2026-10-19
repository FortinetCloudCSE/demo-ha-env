---
title: "Inspection VPC and FGCP HA"
chapter: false
menuTitle: "Inspection VPC and HA"
weight: 31
---

## Overview

Each site has one inspection VPC with a FortiGate FGCP active-passive pair. The primary runs in AZ1 and the secondary in AZ2.
The two units do not share interface addresses, because they sit in different subnets. FortiOS moves the **cluster EIP** to
the new primary on failover, and the session table and configuration are synchronized between the units.

## Interfaces

| Port | Subnet | Role |
|---|---|---|
| port1 | public | the cluster EIP (primary only), IPsec, VIPs, internet NAT |
| port2 | private | the GRE underlay to the TGW Connect peers |
| port3 | ha-mgmt (public, EIP) | unicast heartbeat, configuration sync **and** the HA management interface: GUI/SSH and the EC2 API (see [Management](../3_2_management/)) |
| port4 | management VPC (no EIP) | FortiManager (FGFM only) and FortiAnalyzer logging |

The addresses on port1 to port3 are pinned on the ENIs (`data_host_ip`, default 4) and configured statically in FortiOS.
A DHCP lease did not come back on the standby unit after a reboot, so DHCP is not used.

<!-- TODO: replace with Lucidchart export (HA interfaces and subnets): demo-ha.png -->
```
        AZ1 subnets                         AZ2 subnets
   public   10.1.0.0/24  ── port1 ──┐   ┌── port1 ──  public   10.1.1.0/24
   private  10.1.2.0/24  ── port2 ──┤   ├── port2 ──  private  10.1.3.0/24
   ha-mgmt  10.1.4.0/24  ── port3 ──┼───┼── port3 ──  ha-mgmt  10.1.5.0/24
   (public, IGW route, EIP on port3)                (public, IGW route, EIP on port3)
   tgw      10.1.6.0/24  (TGW attachment)            tgw      10.1.7.0/24
                              PRIMARY    SECONDARY
                         port4 ─► management VPC ◄─ port4   (no EIP)
```

## The heartbeat

FGCP in AWS runs in unicast. The configuration in `terraform/modules/site/templates/fgt-config.tpl` is:

```
config system ha
    set group-name <prefix>-site-a
    set mode a-p
    set hbdev port3 50
    set session-pickup enable
    set unicast-hb enable
    set unicast-hb-peerip <peer port3 address>
    set override disable
    set priority 255            (1 on the secondary)
end
```

The heartbeat is **UDP 730**. Configuration sync uses 703. The ha-mgmt security group allows **all traffic from the whole
inspection VPC CIDR** (not just the peer's address) and TCP 443, TCP 22 and ICMP **only from `management_cidr_sg`**.

{{% notice warning %}}
**Why the whole VPC CIDR?** During testing, the secondary's heartbeat followed the port1 default route and left with a port1
source address (10.1.1.4) instead of its port3 address. The primary ignores heartbeat that does not come from its configured peer,
and the cluster split. The ha-mgmt SG then dropped it as well. The wide security group lets that traffic through. The
FGCP reference configuration has no extra static route for the peer's subnet, and neither does this design. Check
`get system ha status` and the checksums after the first boot. A reboot of the secondary re-joined the cluster when this happened.
{{% /notice %}}

## Where the cluster EIP lives

Only the primary's port1 has the cluster EIP. The IPsec tunnel terminates on it, and so do the SSH VIPs. On failover FortiOS
re-associates the EIP using EC2 API calls. Terraform ignores drift on that association (`lifecycle.ignore_changes`).

{{% notice info %}}
**Port3's EIP stays with its unit.** Per the FGCP reference, failover reassigns the cluster EIP on the **data-plane** ENI's
primary IP (port1) and the route targets that point at the old master. The EIP on the HA-management port (port3, defined in
`config system ha` as `ha-mgmt-interface`) is each unit's own and does not move. When the management ENI was created *outside* the
HA configuration and carried EIPs (an earlier design), failover moved them around. Port4 now has no EIP.
{{% /notice %}}

{{% notice info %}}
**Failover and GRE.** The Connect peers point at the **primary's** port2 address only, so a failover does **not** move the
TGW GRE tunnels. The cluster EIP and the IPsec tunnel do fail over. This is a known limitation of the demo.
{{% /notice %}}

## Verify

```
get system ha status
diagnose sys ha checksum cluster
get system ha status | grep -i member
```

Both units should report the same checksums. See [Validation](../../5_validation/).
