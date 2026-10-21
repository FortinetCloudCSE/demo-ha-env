---
title: "Verify and Troubleshoot"
chapter: false
menuTitle: "Verify and Troubleshoot"
weight: 64
---

This page shows how to prove the VRF design works on a running pair, how to read the debug output, and what a problem looks like.
Run everything on the **primary** of one site. The standby shows an empty routing table and no BGP, which is normal for an FGCP
standby.

## Quick check

Five checks, about two minutes. If all pass, the design is working. The steps below explain each one and the output.

| Check | Command | Pass |
|---|---|---|
| The configuration parsed | `diagnose debug config-error-log read` | prints nothing |
| BGP is up per VRF | `get router info bgp summary` | east neighbors under `VRF 10`, west under `VRF 20`, all `Established`, nothing under the default VRF |
| Routes are separated | `get router info routing-table all` | a section each for `VRF=10` and `VRF=20`, with the leaked routes marked `S D` |
| Egress works | from a spoke, `curl -s -m 10 https://ifconfig.me` | returns the site's cluster EIP |
| The setting is in use | `diagnose sys session list` for a VIP session | the session header shows `skip_vrf` |


The design needs the static routes in [Building It](../6_2_building_it/) and `skip-vrf-match` on the policies that cross to port1. The steps
below show each piece working. Steps 4 and 5 turn the setting off to show that it is the reason.

## Step 1: Is the VRF configuration there?

A stanza in the bootstrap that fails to parse fails silently, so check the error log first:

```
diagnose debug config-error-log read
```

It should print nothing. Then check that the settings are in place:

```
show system interface gre-east         # set vrf 10
show router static                     # routes 30 to 71, with set vrf
show router bgp                        # neighbors with set interface and set update-source
show firewall policy 1                 # set skip-vrf-match enable
show firewall policy | grep -B3 -A12 "ssh-to-site-a-east"
```

For the VIP policy, `skip-vrf-match enable` should be listed along with the source address objects (`admin-src-1` and so on).

## Step 2: Do the routing tables separate?

```
get router info routing-table all
```

The output has one section per VRF: `VRF=default(0)`, `VRF=1` (management), `VRF=10` and `VRF=20`. On the site A primary expect:

| VRF | What it should contain |
|---|---|
| 10 (east) | `0.0.0.0/0` via port1 (`S*D`), the east spoke CIDR from BGP (`B`), the remote east CIDR via `gre-east-x` (`S D`), the TGW CIDR via port2 (`S D`), and the connected `gre-east` and `gre-east-x` addresses |
| 20 (west) | the same, for west and `gre-west`, `gre-west-x` |
| 0 (default) | port1 and port2 connected, the leaked return routes to each spoke CIDR via `gre-east` and `gre-west` (`S D`), the IPsec tunnel address, and no BGP routes |

How to read the codes: `C` connected, `S` static, `B` BGP. **`D` means directly leaked**: the route is in this VRF but its exit
interface is in another VRF. The default route in VRF 10 and the spoke return route in VRF 0 are the two leaks that internet
egress and the VIPs depend on.

{{% notice info %}}
`get router info routing-table vrf 10` is not a valid command on FortiOS 8.0.1. Use `routing-table all`, which prints every VRF.
{{% /notice %}}

## Step 3: Does the SSH VIP work, and is the setting applied?

Open an SSH session to the **primary's port3 address** (the management EIP) and start the debug **before** you connect to the VIP:

```
diagnose debug reset
diagnose debug flow filter dport 2222
diagnose debug flow show function-name enable
diagnose debug flow trace start 40
diagnose debug enable
```

Then from your laptop connect to the **cluster EIP** (not the port3 EIP): `ssh -p 2222 ec2-user@<cluster EIP>`. When it connects,
keep that session open and run these in your management session:

```
diagnose sys session filter clear
diagnose sys session filter dport 2222
diagnose sys session list
diagnose debug disable
```

**Why `dport 2222` and not 22.** The VIP listens on 2222 on the cluster address and is translated to 22 on the spoke. The debug and
session filters see the packet as it arrives, before the translation, so the port to match is 2222. Filtering on port 22 instead
matches your own administration sessions to the FortiGate's SSH server on port3, which show `state=local` and
`policy_id=4294967295`. It is an easy mistake and it hides the VIP traffic entirely.

What the debug shows for the first packet, and what each line means:

```
vd-root:0 received a packet(proto=6, x.x.x.x:49936->10.1.0.4:2222) ... from port1. flag [S]
allocate a new session-000009b0
find DNAT: IP-10.1.10.132, port-22
VIP-10.1.10.132:22, outdev-port1
DNAT 10.1.0.4:2222->10.1.10.132:22
find a route: flag=00000000 gw-169.254.6.2 via gre-east
Allowed by Policy-10:
```

| Line | Meaning |
|---|---|
| `vd-root:0 received a packet ... from port1` | the packet arrived on port1, so the session is created in **VRF 0** (`vd-root:0`) |
| `allocate a new session` | no existing session matched, so a new one is created |
| `find DNAT` / `DNAT 10.1.0.4:2222->10.1.10.132:22` | the VIP translates the destination to the spoke instance and port 22 |
| `find a route ... via gre-east` | the routing lookup found the leaked return route (route 70 in VRF 0), whose exit interface is in VRF 10 |
| `Allowed by Policy-10` | the VIP policy accepted it |

In the session list look at these fields:

```
session info: proto=6 ... refresh_dir=both skip_vrf ...
orgin->sink: org pre->post, reply pre->post dev=3->15/15->3 gwy=169.254.6.2/10.1.0.1
hook=pre  dir=org   act=dnat x.x.x.x:49936->10.1.0.4:2222(10.1.10.132:22)
hook=post dir=reply act=snat 10.1.10.132:22->x.x.x.x:49936(10.1.0.4:2222)
misc=0 policy_id=10 ... vd=0
```

| Field | Meaning |
|---|---|
| `skip_vrf` | the session was created with `skip-vrf-match`. If this flag is missing the setting is not on the policy |
| `policy_id=10` | the VIP policy matched |
| `vd=0` | the session lives in VRF 0 |
| `dev=3->15/15->3` | two different interface indexes, one forward and one for the reply path |
| `gwy=169.254.6.2/10.1.0.1` | the forward direction goes to the TGW side (`gre-east`); the reply goes toward the client through the port1 gateway |
| `act=dnat` / `act=snat` | the destination translation on the way in and the reverse translation on the reply |

## Step 4: Prove the setting is the reason (VIP)

Turn the option off and try again:

```
config firewall policy
    edit 10
        unset skip-vrf-match
    next
end
diagnose sys session filter clear
diagnose sys session clear
```

{{% notice warning %}}
`diagnose sys session clear` with the filter cleared removes **every** session, including your own administration session on port3.
Reconnect after it. To avoid this, leave the `dport 2222` filter in place so only the VIP sessions are cleared.
{{% /notice %}}

This time the filter has to match the **reply**, which comes from the spoke instance (source `10.1.10.132`), not the client:

```
diagnose debug reset
diagnose debug flow filter addr 10.1.10.132
diagnose debug flow show function-name enable
diagnose debug flow trace start 40
diagnose debug enable
```

Try the SSH to the VIP again. It hangs. After about 15 seconds `diagnose debug disable` and look for:

```
vd-root:10 received a packet(proto=6, 10.1.10.132:22->x.x.x.x:50021) ... from gre-east. flag [S.]
find a route: flag=00000000 gw-10.1.0.1 via port1
no session matched
```

This is the failure the design has to avoid. The SYN-ACK from the instance arrives on `gre-east`, which is in VRF 10 (`vd-root:10`). The
session was created in VRF 0. Without `skip-vrf-match`, FortiOS looks for the session in the VRF the reply arrived in, finds none,
and drops it (`no session matched`). The instance keeps retransmitting the SYN-ACK, so the message repeats. **Put the setting back
before you go on:**

```
config firewall policy
    edit 10
        set skip-vrf-match enable
    next
end
```

## Step 5: Internet egress

From a spoke instance (SSM session):

```
curl -s -m 10 https://ifconfig.me
```

It prints the **cluster EIP** of that site. To see the path, start this on the primary first:

```
diagnose debug reset
diagnose debug flow filter addr 10.1.10.132
diagnose debug flow show function-name enable
diagnose debug flow trace start 40
diagnose debug enable
```

```
vd-root:10 received a packet(proto=6, 10.1.10.132:55926->44.254.14.214:443) ... from gre-east. flag [S]
allocate a new session-000004e4
find a route: flag=00000000 gw-10.1.0.1 via port1
find SNAT: IP-10.1.0.4(from IPPOOL), port-55926
Allowed by Policy-1: SNAT
vd-root:0 received a packet(proto=6, 44.254.14.214:443->10.1.0.4:55926) ... from port1
Find an existing session, id-000004e4, reply direction
DNAT 10.1.0.4:55926->10.1.10.132:55926
```

| Line | Meaning |
|---|---|
| `vd-root:10 ... from gre-east` | the spoke's packet arrived on a VRF 10 interface, so the session is created in **VRF 10** |
| `find a route ... via port1` | the leaked default route in VRF 10 (route 60) sends it out port1, which is in VRF 0 |
| `find SNAT: IP-10.1.0.4` / `Allowed by Policy-1: SNAT` | policy 1 accepted it and translated the source to the port1 address |
| `vd-root:0 ... from port1` | the reply arrives in **VRF 0**, a different VRF from the session |
| `Find an existing session ... reply direction` | **this is `skip-vrf-match` working**: the reply found the session created in VRF 10 |
| `DNAT 10.1.0.4:55926->10.1.10.132:55926` | the reply is translated back to the spoke and goes out `gre-east` |

To see it fail, run `unset skip-vrf-match` on policy 1 and repeat the curl. It returns nothing. The debug above still shows the SYN
leaving (`Allowed by Policy-1: SNAT`, repeated as the client retransmits) but there is **no `from port1` reply line**, because the reply
is dropped.

{{% notice info %}}
The filter above uses the spoke's address, and the failed reply is addressed to the port1 address (`10.1.0.4`) after the translation. A
reply that does not match a session is therefore hidden by that filter, which is why the failure shows as a missing line. To see the explicit
`no session matched` for egress, filter on the reply instead, with `diagnose debug flow filter daddr 10.1.0.4` and `diagnose debug flow filter sport 443`.
This variant was suggested but was not captured in the test run.
{{% /notice %}}

Put the setting back (`set skip-vrf-match enable` on policy 1) and run the curl again to confirm it returns the EIP.

## Step 6: Across the sites, and isolation

From the spoke instances:

| From | To | Expect |
|---|---|---|
| site A east | site B east | works (about 1 to 2 ms) |
| site A west | site B west | works |
| site B east | site A east | works |
| site A east | site A west, or site B west | fails (isolation) |
| any spoke | the internet | works, returns the site's cluster EIP |

The same-customer pings never leave their VRF, so they do not depend on `skip-vrf-match`. The isolation pings fail because there
is no route between the customer VRFs. Policy 7 is there to deny and log the attempt (the log entry was not checked in this test).

## Common mistakes while testing

| Symptom | Cause |
|---|---|
| The flow debug prints nothing | the filter does not match the packet as it arrives (use the pre-translation port, and the address of the side that sends the packet you want to see), or `diagnose debug enable` was not run |
| The session list shows only `state=local` sessions | the filter matched administration sessions to the FortiGate; use the VIP port (2222), not 22 |
| The VIP times out but nothing is dropped | the source is not in `management_cidr_sg`, so the VIP policy never matches; check `show firewall address` |
| `get router info routing-table vrf 10` fails to parse | not valid on 8.0.1; use `routing-table all` |
| One BGP neighbor sits in `Active` for a few minutes | normal after boot; it came up on its own in testing |
| You were disconnected during a test | `diagnose sys session clear` without a filter removes your own session; reconnect |
| The SSH to the cluster EIP reaches the FortiGate itself | you used the port3 EIP; use the cluster EIP |

Leave the system as you found it: `diagnose debug disable` and `diagnose debug reset`, and `show firewall policy 1` and
`show firewall policy | grep -A14 ssh-to` should show `skip-vrf-match enable` again.

## What a problem looks like

| Symptom | Likely cause | What to check |
|---|---|---|
| Egress from a spoke times out; the debug shows the SYN leaving port1 repeatedly and no reply | `skip-vrf-match` is missing on policy 1 or 2 | `show firewall policy 1`; the setting is unset on the policy |
| The SSH to a VIP hangs, and the debug on the spoke's address shows `no session matched` on a packet from `gre-east` | `skip-vrf-match` is missing on the VIP policy | `show firewall policy` for the `ssh-to-` policy |
| A tunnel is up but no traffic passes, and `txe` climbs on the GRE interface (`diagnose netlink interface list gre-east`) | the VRF has no route to the tunnel's outer destination | the underlay routes, 30 and 40 (TGW) and 50 and 51 (other site), with `set vrf` |
| A BGP neighbor sits in `Active` for a few minutes after boot | normal; it came up on its own in testing | check again before troubleshooting |
| A neighbor never leaves `Active` | the underlay route for that VRF, or the neighbor has no `set interface` | the underlay route and `show router bgp` |
| Same-customer ping across the sites fails, but egress works | the remote CIDR route (20 or 21) or the other site's side | `get router info routing-table all` shows the other site's CIDR via `gre-<c>-x` in the customer VRF, then the same on site B |
| A spoke can reach the other customer | an isolation break | the policies; a `deny-east-west` policy should be last, and the VRFs should have no route between them |
