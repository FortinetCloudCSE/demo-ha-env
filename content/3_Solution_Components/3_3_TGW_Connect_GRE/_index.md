---
title: "TGW Connect (GRE)"
chapter: false
menuTitle: "TGW Connect (GRE)"
weight: 33
---

## Overview

Each spoke VPC reaches the firewall through **TGW Connect**: a GRE tunnel with eBGP between the TGW and the primary FortiGate's
port2. There is no inspection-VPC routing and no Gateway Load Balancer. Each spoke (east, west) has its own Connect attachment
and its own Connect peer, which is what makes the customers separable at the TGW.

<!-- TODO: replace with Lucidchart export (TGW Connect): demo-connect.png -->
```
   east VPC ──► TGW spoke_rt[east]  ◄── BGP routes ──┐
                    ▲                                │
   TGW connect_rt[east] ◄── east CIDR                │      FortiGate primary
                    │                                └──────  gre-east  (AS 65001)
   Connect attachment [east] ═══ GRE 10.254.x.10 ═════════════ port2
                                                              
   west VPC ──► TGW spoke_rt[west]  ◄── BGP routes ──┐
   TGW connect_rt[west] ◄── west CIDR                └──────  gre-west
   Connect attachment [west] ═══ GRE 10.254.x.11 ═════════════ port2
```

The inspection VPC's regular TGW attachment still exists, but only as the **transport** that AWS requires for Connect. A
`transport` route table is associated with it and stays empty, so nothing ever routes through it.

## TGW route tables (two per spoke)

| Table | Associated with | Learns |
|---|---|---|
| `spoke_rt` | the spoke VPC attachment | the default route and the remote-site CIDRs from the FortiGate (Connect propagation) |
| `connect_rt` | the Connect attachment | only that spoke's CIDR (propagation from the spoke attachment) |

Because each spoke has its own pair, the east spoke only learns what the east Connect peer advertises.

## FortiGate side

```
config system gre-tunnel
    edit gre-east
        set interface port2
        set local-gw <port2 address>
        set remote-gw <TGW GRE address, host 10>
    next
end
config system interface
    edit gre-east
        set ip 169.254.6.1 255.255.255.255
        set remote-ip 169.254.6.2 255.255.255.248
        set mtu-override enable
        set mtu 1400
    next
end
config router bgp
    set as 65001
    config neighbor
        edit 169.254.6.2
            set remote-as 64512
            set ebgp-enforce-multihop enable
            set capability-default-originate enable
            set prefix-list-out pl-east-out
        next
        (a second neighbor 169.254.6.3 for the second TGW peer)
    end
end
```

- The FortiGate **originates a default route** to the TGW, which is how the spokes get internet egress.
- The FortiGate advertises only the **remote-site prefix of that customer** (the `prefix-list-out`), and learns the local spoke prefix.
- The GRE underlay addresses (10.254.x.10, .11) are reached through port2 by a static route, not the port1 default.

{{% notice warning %}}
**The default route must be in the prefix-list.** An outbound prefix-list also filters the default route that
`capability-default-originate` produces. With only the remote-site prefix listed, the neighbor showed
`Default information originate, default not sent`, so the spokes had no route back through the firewall (the SSH VIPs timed
out and the instances had no internet egress). Each `pl-<customer>-out` therefore has two rules: the customer's remote prefix
and `0.0.0.0 0.0.0.0`. Check with `get router info bgp neighbors <peer>` and look for "default sent".
{{% /notice %}}

## Verify

```
get router info bgp summary                 # four neighbors Established
get router info routing-table all           # local spokes by BGP
diagnose sniffer packet port2 'proto 47' 4 0 l
```
