---
title: "Building It"
chapter: false
menuTitle: "Building It"
weight: 62
---

These are the settings the bootstrap template builds for each customer, on the site A primary for **east** (VRF 10). West is the same
with VRF 20 and `gre-west`. The IDs are the static route IDs in `fgt-config.tpl`.

## 1. Put the customer's tunnels in its VRF

```
config system interface
    edit "gre-east"
        set vrf 10
    next
    edit "gre-east-x"
        set vrf 10
    next
end
```

`get router info routing-table all` then prints one routing table per VRF: the tunnel's connected addresses move to VRF 10.

## 2. Put the customer's BGP neighbors in the VRF

A BGP neighbor has **no `vrf` option**. It joins a VRF through its interface:

```
config router bgp
    config neighbor
        edit 169.254.6.2
            set interface "gre-east"
            set update-source "gre-east"
        next
        (the same for 169.254.6.3)
    end
end
```

`get router info bgp summary` then lists the neighbors under `VRF 10`, and west under `VRF 20`.

## 3. Give each VRF a route for the tunnel underlay

A GRE tunnel in a VRF looks up its **outer** destination in that VRF. The TGW address (`10.254.1.x`) is reached through port2, which is
in the default VRF, so the VRF needs its own route to it. The same goes for the tunnel to the other site, whose underlay is the IPsec
interface.

```
config router static
    edit 30
        set dst 10.254.1.0 255.255.255.0     # the TGW CIDR, for gre-east
        set gateway 10.1.2.1
        set device "port2"
        set vrf 10
    next
    edit 50
        set dst 169.254.100.2 255.255.255.255   # the other site's tunnel address, for gre-east-x
        set device "to-site-b"
        set vrf 10
    next
end
```

The route is in VRF 10 and the exit interface is in VRF 0. A route like that is a **leaked route**, shown as `S D` in the routing table
(`D` means directly leaked).

## 4. Route the customer's traffic to the other site

```
config router static
    edit 20
        set dst 10.2.10.0 255.255.255.0      # site B east
        set device "gre-east-x"
        set vrf 10
    next
end
```

## 5. Let the customer's traffic reach port1, and the replies reach the spokes

Internet egress and the VIPs need two more leaked routes:

```
config router static
    edit 60
        set gateway 10.1.0.1                 # the port1 gateway; destination defaults to 0.0.0.0/0
        set device "port1"
        set vrf 10                           # the default route for VRF 10
    next
    edit 70
        set dst 10.1.10.0 255.255.255.0      # the east spoke CIDR
        set device "gre-east"
        set vrf 0                            # the way back, in the default VRF where port1 is
    next
end
```

Route 60 sends egress traffic from VRF 10 out port1. Route 70 lets a packet that arrives on port1 find its way to the spoke through
`gre-east`.

## 6. Set `skip-vrf-match` on the policies that cross to port1

```
config firewall policy
    edit 1                                   # east-to-internet
        set srcintf "gre-east"
        set dstintf "port1"
        set nat enable
        set skip-vrf-match enable
    next
    edit 10                                  # ssh-to-site-a-east, the VIP policy
        set srcintf "port1"
        set dstintf "gre-east"
        set skip-vrf-match enable
    next
end
```

The routes in steps 3 to 5 make the **routing lookup** work in both directions. They do not change which VRF a packet belongs to,
and a session is looked up in the VRF of the interface its packet arrives on. `skip-vrf-match` is what makes the **session lookup**
work, and [Cross-VRF Traffic](../6_3_cross_vrf_traffic/) explains how.

The inter-site policies (3 to 6) stay inside one VRF and do not set it.

## Route summary

| ID | VRF | Destination | Exit | Purpose |
|---|---|---|---|---|
| 10 | 0 | the TGW CIDR | port2 | underlay for the shared default VRF |
| 20, 21 | customer | the other site's customer CIDR | `gre-<c>-x` | cross-site traffic stays in the customer's VRF |
| 30, 40 | customer | the TGW CIDR | port2 | underlay for `gre-<c>` |
| 50, 51 | customer | the other site's tunnel address | the IPsec interface | underlay for `gre-<c>-x` |
| 60, 61 | customer | `0.0.0.0/0` | port1 | egress and VIP replies leave the customer VRF |
| 70, 71 | 0 | the customer's local spoke CIDR | `gre-<c>` | the way back from port1 to the spokes |
