---
title: "What Worked"
chapter: false
menuTitle: "What Worked"
weight: 62
---

## 1. A VRF on a GRE interface

```
config system interface
    edit "gre-east"
        set vrf 10
    next
    edit "gre-west"
        set vrf 20
    next
end
```

`show system interface gre-east` confirmed `set vrf 10`, and the routing table split into one table per VRF:

```
Routing table for VRF=default(0)
S*  0.0.0.0/0      [10/0] via 10.1.0.1, port1
C   10.1.0.0/24    is directly connected, port1
C   10.1.2.0/24    is directly connected, port2
S   10.254.1.0/24  [10/0] via 10.1.2.1, port2

Routing table for VRF=10
C   169.254.6.0/29 is directly connected, gre-east
C   169.254.6.1/32 is directly connected, gre-east

Routing table for VRF=20
C   169.254.7.0/29 is directly connected, gre-west
C   169.254.7.1/32 is directly connected, gre-west
```

The BGP-learned spoke routes disappeared from the default VRF: the neighbors were not in the new VRF.

## 2. Putting a BGP neighbor in a VRF

The neighbor has **no `vrf` option**. `set ?` on a neighbor lists `interface`, `update-source` and many address-family
options, but nothing named `vrf`. `get router info bgp ?` has no VRF argument either. Only `config vrf` (route-target
leaking) and the `vpnv4` and `evpn` views point at an L3VPN-style model.

What worked was naming the neighbor's **interface**:

```
config router bgp
    config neighbor
        edit 169.254.6.2
            set interface gre-east
            set update-source gre-east
        next
        (the same for 169.254.6.3, and gre-west for 169.254.7.2 and .3)
    end
end
```

The summary then listed the neighbors under their VRFs:

```
VRF 10 BGP router identifier 10.1.0.4, local AS number 65001
Neighbor     V   AS     MsgRcvd MsgSent  Up/Down  State/PfxRcd
169.254.6.2  4   64512  ...     ...      never    Active
169.254.6.3  4   64512  ...     ...      never    Active

VRF 20 BGP router identifier 10.1.0.4, local AS number 65001
169.254.7.2  4   64512  ...
169.254.7.3  4   64512  ...
```

## 3. The GRE underlay lookup follows the tunnel's VRF

The sessions stayed in `Active`. A sniffer on port2 showed GRE arriving from the TGW (10.254.1.10 → 10.1.2.4) but nothing
leaving. The tunnel's transmit-error counter was climbing:

```
diagnose netlink interface list gre-east
stat: rxp=6518 txp=27708 ... txe=128   →   txe=142   →   txe=146
```

Moving the tunnel into VRF 10 made FortiOS look up the **outer destination** (10.254.1.10) in VRF 10. That route lived only in
the default VRF (`10.254.1.0/24 via 10.1.2.1, port2`), so each transmit failed.

## 4. A static route can name a VRF, and a device in another VRF

`config router static` / `edit n` / `set ?` includes a `vrf` field. This installs the TGW route into each customer VRF with
port2 (default VRF) as the exit interface:

```
config router static
    edit 99
        set dst 10.254.1.0 255.255.255.0
        set gateway 10.1.2.1
        set device port2
        set vrf 10
    next
    edit 98
        set dst 10.254.1.0 255.255.255.0
        set gateway 10.1.2.1
        set device port2
        set vrf 20
    next
end
```

```
Routing table for VRF=10
S D  10.254.1.0/24 [10/0] via 10.1.2.1, port2
```

`D` means "directly leaked". Within a minute BGP came up in both VRFs, and each VRF learned only its own customer:

```
Routing table for VRF=10
B   10.1.10.0/24 [20/100] via 169.254.6.3 (recursive is directly connected, gre-east)

Routing table for VRF=20
B   10.1.20.0/24 [20/100] via 169.254.7.2 (recursive is directly connected, gre-west)
```

**Result.** The tunnel-to-TGW half of the design works with VRFs. The routing tables are separated.

## 5. Routes out to the internet and back in to the spokes

Two more leaked static routes made the *routing lookups* succeed:

```
config router static
    edit 90
        set dst 0.0.0.0 0.0.0.0
        set gateway 10.1.0.1
        set device port1
        set vrf 10                 (and 91 with vrf 20)
    next
    edit 80
        set dst 10.1.10.0 255.255.255.0
        set device gre-east
        set vrf 0                  (and 81 for 10.1.20.0/24 via gre-west)
    next
end
```

```
get router info routing-table details 10.1.10.4
Routing table for VRF=default(0)
  Known via "static" ... * vrf default(0) 169.254.6.2, via gre-east
Routing table for VRF=10
  Known via "bgp" ...    * vrf 10 169.254.6.3 (recursive is directly connected, gre-east)
```

Every route lookup now returned the right answer. The traffic still failed. See [Why It Fails](../6_3_why_it_fails/).
