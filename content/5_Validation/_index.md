---
title: "Validation"
chapter: false
menuTitle: "Validation"
weight: 50
---

Work bottom-up: HA first, then the management plane, then each tunnel layer, then traffic.

## 1. HA

```
get system ha status
diagnose sys ha checksum cluster
```

Both units list two members and report matching checksums.

## 2. Licensing

```
get system status | grep -i License
```

PAYG shows `License Status: Valid`.

## 3. Management

```
show system ha | grep -A4 ha-mgmt
get router info routing-table all             # VRF=1: 10.99.0.0/24 via port4
get system central-management | grep -i -e fmg -e interface   # specify, port4, vrf-select 1
get system central-management
```

The GUI answers on every unit's port3 EIP, and the EIP stays with its unit after a failover (check the EIP association in the console before and after).

## 4. IPsec to the other site

```
diagnose vpn ike gateway list
diagnose vpn tunnel list
```

## 5. TGW Connect (GRE and BGP)

```
get system interface | grep -A3 gre
diagnose netlink interface list gre-east
get router info bgp summary
get router info bgp neighbors 169.254.6.2 received-routes
get router info bgp neighbors 169.254.6.2 advertised-routes
diagnose sniffer packet port2 'proto 47' 4 0 l
```

Expect **four** neighbors `Established`: 169.254.6.2 and .3 (east, listed under `VRF 10`), 169.254.7.2 and .3 (west, listed
under `VRF 20`). Nothing is listed under the default VRF. You receive the local spoke prefix; you advertise the other site's
prefix for **that customer only**. A neighbor can take a few minutes after boot to establish, so check again before
troubleshooting one that shows `Active`.

| Symptom | Likely cause |
|---|---|
| Neighbors stuck in `Connect` or `Active` | GRE not passing: check the sniffer, the Connect peer address and the TGW CIDR route via port2 |
| `txe` climbing on a GRE interface | the outer destination has no route from that interface's table |
| Established but no routes | check the TGW route tables and the prefix-lists |

## 6. Inter-site GRE

```
execute ping 169.254.10.2          # east, other site
execute ping 169.254.20.2          # west, other site
get router info routing-table all  # remote east CIDR via gre-east-x in VRF 10, remote west via gre-west-x in VRF 20
diagnose netlink interface list gre-east-x
```

## 7. VRFs and the cross-VRF path

```
diagnose debug config-error-log read   # prints nothing
get router info bgp summary            # east neighbors under VRF 10, west under VRF 20
get router info routing-table all      # one section per VRF; leaked routes show as S D
show firewall policy 1                 # set skip-vrf-match enable
```

From a spoke, `curl -s -m 10 https://ifconfig.me` should return the site's cluster EIP, and an SSH to a VIP on the cluster EIP should connect.
The full walkthrough, with the flow debug, the session list, and how to prove `skip-vrf-match` is the reason, is in
[VRF Isolation: Verify and Troubleshoot](../6_vrf_isolation/6_4_verify_and_troubleshoot/).

## 8. Traffic

See [Use Cases](../7_usecases/): internet egress from a spoke, cross-site traffic per customer, and the isolation test.
