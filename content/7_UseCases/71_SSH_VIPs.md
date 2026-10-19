---
title: "SSH VIPs"
weight: 1
---

## Admin access to a spoke instance

The spoke VPCs have no IGW and no public addresses. Per-site VIPs on the cluster EIP forward a public TCP port to SSH on a
spoke instance, limited to a set of admin source addresses.

<!-- TODO: replace with Lucidchart export (VIP path): demo-uc-vip.png -->
```
   admin ──► cluster EIP:2222 ──► port1 ──DNAT──► 10.1.10.<host>:22
                                    │
                              policy 10+ (admin-src only, nat disable)
                                    ▼
                               gre-east ──► TGW ──► east spoke instance
```

## Configuration

```hcl
ssh_admin_sources = { admin-src = "203.0.113.10/32" }
site_a_ssh_forwards = [
  { name = "east", port = 2222, spoke = "east" },
  { name = "west", port = 2223, spoke = "west" },
]
```

`terraform/templates/ssh-forwards.tpl` renders, per forward: a service object, a VIP (`vip-ssh-<site>-<name>`, port forwarding to 22)
and a policy from port1 to `gre-<spoke>` with `nat disable`. The policy IDs start at **10** so they do not collide with the
isolation policies 1 to 7.

NAT is disabled because the GRE inside addresses (169.254.x) are not routable from the spokes. The spoke security group
therefore allows SSH from anywhere, and the FortiGate policy decides who gets in.

## Test

```
ssh -p 2222 ec2-user@<site A cluster EIP>        # east instance
ssh -p 2223 ec2-user@<site A cluster EIP>        # west instance
```

The key is the one named in `keypair`.

## If it fails

```
diagnose debug reset
diagnose debug flow filter clear
diagnose debug flow filter saddr <your public IP>
diagnose debug flow filter dport 2222
diagnose debug flow show function-name enable
diagnose debug flow trace start 30
diagnose debug enable
```

Retry the SSH, then `diagnose debug disable` and `diagnose debug reset`. Look for `Allowed by Policy-10` and the DNAT line.
No output means the packet never arrived: check the port1 security group and the source address. A SASE tunnel changes
your source address.

{{% notice info %}}
Debug output only prints in an interactive session, not from a script.
{{% /notice %}}
