---
title: "Cross-Site Traffic"
weight: 3
---

## East to east, west to west, across the sites

An east instance at site A reaches the east instance at site B through `gre-east-x`, which rides inside the IPsec tunnel. West
uses `gre-west-x`.

<!-- TODO: replace with Lucidchart export (cross-site path): demo-uc-crosssite.png -->
```
   site A east ─► TGW ─► gre-east ─► FortiGate A ─► gre-east-x ═► IPsec ═► FortiGate B ─► gre-east ─► TGW ─► site B east
                              policy 3                                     policy 4 (on B)

   site A west ─► TGW ─► gre-west ─► FortiGate A ─► gre-west-x ═► IPsec ═► FortiGate B ─► gre-west ─► TGW ─► site B west
                              policy 5                                     policy 6 (on B)
```

## Test

From the site A east instance:

```
ping 10.2.10.<host>        # site B east spoke
```

On the site A primary, watch it ride `gre-east-x`:

```
diagnose sniffer packet gre-east-x 'icmp' 4 10 l
get router info routing-table all | grep 10.2.10
```

Expected: the route is `10.2.10.0/24` via `gre-east-x`, and the ICMP shows on `gre-east-x` and not on `gre-west-x`.

## What you are proving

- East traffic uses the east tunnel only; the west tunnel counters do not move
- The IPsec tunnel is the only path between the sites (the spokes have no other route)

```
diagnose netlink interface list gre-east-x      # packet counters rise
diagnose netlink interface list gre-west-x      # counters unchanged
```

{{% notice warning %}}
Unverified on a unit. This is the first test of the inter-site GRE tunnels. If the ping fails, check in order: IPsec up,
`execute ping 169.254.10.2`, the route, then policies 3 and 4.
{{% /notice %}}
