# demo-ha-env

Terraform for a customer demo of FortiGate in AWS: two FortiGate FGCP HA pairs, each in its own inspection VPC,
joined by an IPsec tunnel, with east and west workload VPCs behind each pair and one shared management VPC
(FortiManager and FortiAnalyzer) that every FortiGate also attaches to.

This is demo code, not a production reference. See [Status and caveats](#status-and-caveats).

## What it builds

```
                       Site A                                              Site B
   ┌───────────────────────────────────────────┐        ┌───────────────────────────────────────────┐
   │ east VPC ─┐                               │        │                               ┌─ east VPC │
   │           ├─ TGW ══GRE══ FortiGate HA pair ═══IPsec═══ FortiGate HA pair ══GRE══ TGW ┤           │
   │ west VPC ─┘   (Connect)   (inspection VPC)│ internet│  (inspection VPC)   (Connect)   └─ west VPC │
   └───────────────────────────────────────────┘        └───────────────────────────────────────────┘
                         │ port4 (multi-VPC ENI, no EIP)               │ port4 (multi-VPC ENI, no EIP)
                         └───────────────────┐        ┌────────────────┘
                                     Management VPC: FortiManager + FortiAnalyzer
```

- **Two sites, one account and region.** Each site has an inspection VPC with a FortiGate A-P FGCP pair (two AZs),
  a transit gateway, and east and west spoke VPCs attached to that TGW.
- **IPsec between the sites.** Cluster EIP to cluster EIP, IKEv2, route-based. The IPsec interface carries a /32 on each
  side (169.254.100.0/30) and the customers ride inside it on their own GRE tunnels: `gre-east-x` (key 10, 169.254.10.0/30)
  and `gre-west-x` (key 20, 169.254.20.0/30). Static routes send each customer's remote spoke CIDR into its own tunnel
  (no BGP between the sites). Inter-site traffic has to use the tunnel.
- **Customer isolation with VRFs.** East (VRF 10) and west (VRF 20) each have a GRE tunnel to the TGW and one to the other site
  in their own VRF, their own firewall policies, and a final `deny-east-west` policy that logs any attempt to cross. Each TGW BGP
  peer is sent only the remote prefix of its own customer. Internet egress and the SSH VIPs cross from a customer VRF to port1,
  so those policies set `skip-vrf-match` (without it the reply is dropped with `no session matched`). See the VRF Isolation
  chapter of the docs.
- **Spokes reach the firewall over TGW Connect (GRE).** Each spoke has its own Connect attachment and Connect peer to the
  site's primary FortiGate (port2). eBGP runs over the GRE tunnel: the FortiGate advertises a default route and the
  remote-site prefixes to the TGW and learns the local spoke prefix. The inspection VPC's regular TGW attachment still exists,
  but only as the Connect transport (AWS requires one); no TGW route table uses it.
- **Shared management VPC** with its own IGW, not attached to either TGW. FortiManager and FortiAnalyzer are BYOL, looked up
  by version string. Every FortiGate has a dedicated **port4**, a multi-VPC ENI in the management VPC with **no EIP**, used only
  for FortiManager and FortiAnalyzer (VRF 1, `dedicated-to management`, `allowaccess fgfm` only).
- **HA management on port3.** As in the FGCP reference design, port3 carries the heartbeat, config sync and the HA management
  interface (`ha-mgmt-interface`) on one ENI, in a public subnet with an EIP per unit. The EIP gives each unit (including the
  secondary) its own GUI/SSH address and its own path to the EC2 API. A security group limits GUI/SSH to `management_cidr_sg`.
- **SSH forwards.** Per-site VIPs on the cluster EIP forward a public TCP port (for example 2222 and 2223) to SSH on the east
  and west test instances, limited to a set of admin source addresses.

### FortiGate interfaces

| Port | Role |
|------|------|
| port1 | public: cluster EIP (primary only), IPsec, VIPs, DNS |
| port2 | private: GRE to the TGW Connect peers |
| port3 | combined HA heartbeat (unicast, UDP 730), config sync and HA management interface, in the ha-mgmt subnets (public, with an EIP per unit): GUI/SSH, the EC2 API calls for failover |
| port4 | management VPC (multi-VPC ENI, no EIP, VRF 1, `dedicated-to management`): FortiManager (FGFM only) and FortiAnalyzer logging |

There is no EC2 API VPC endpoint. The failover API calls leave through port3 and its EIP, and port3's EIP is **not** moved on
failover: it is on the HA management interface, so it belongs to its unit. FortiOS moves the cluster EIP (on port1's primary IP)
and the routes that point at the active unit to the new primary, as FGCP does, and an EIP on any other ENI would move with it.
Port4 has no EIP, so there is nothing on it for HA to move. Port4 allows only `fgfm`: no HTTPS, SSH or ping.

### Addressing

- Each inspection VPC is a /21 split into eight /24 subnets (public, private, ha-mgmt, tgw, in two AZs): site A is 10.1.0.0/21,
  so the third octet identifies the subnet (0/1 public, 2/3 private, 4/5 ha-mgmt, 6/7 tgw). Each spoke /24 is split into four /26s.
- The FortiGate port1 to port3 addresses are pinned on the ENIs (host `data_host_ip`, default 4) and configured statically in
  FortiOS, so they are predictable: site A primary is 10.1.0.4 / 10.1.2.4 / 10.1.4.4, the secondary is 10.1.1.4 / 10.1.3.4 / 10.1.5.4.
  (A DHCP lease did not come back on the standby unit after a reboot, so DHCP is not used.)
- GRE: a TGW CIDR block per site (10.254.1.0/24 and 10.254.2.0/24 by default) supplies the TGW-side GRE addresses. The BGP
  inside CIDRs are 169.254.6.0/29 (east) and 169.254.7.0/29 (west): the FortiGate is the first address and the TGW BGP peers
  are the second and third.
- The management IPs of FortiManager, FortiAnalyzer and the FortiGates are pinned (see `terraform/terraform.tfvars.example`), as are
  the spoke test instances (default host 4 of their workload subnet).

## Layout

| Path | Purpose |
|------|---------|
| `terraform/main.tf`, `terraform/management.tf` | provider, FortiGate AMI lookup, management VPC, SGs, FortiManager and FortiAnalyzer |
| `terraform/sites.tf` | cluster EIPs and the two `modules/site` instances |
| `terraform/modules/site/` | one site: inspection VPC, TGW and spokes (`tgw_spokes.tf`), TGW Connect (`connect.tf`), FortiGates (`fortigate.tf`) |
| `terraform/modules/site/templates/fgt-config.tpl` | FortiGate bootstrap config: HA, IPsec, GRE, BGP, policies, FMG/FAZ registration |
| `terraform/modules/site/bootstrap.tf` | S3 bootstrap: bucket, per-unit config and license objects, S3 gateway endpoint, user-data JSON |
| `terraform/templates/ssh-forwards.tpl` | per-site SSH VIPs, rendered into the FortiGate bootstrap |
| `terraform/config_templates/` | FortiManager and FortiAnalyzer bootstrap |
| `generate_network_diagram.sh` | writes `diagram/network_diagram.{svg,md}` from the Terraform outputs |
| `CLAUDE.md` | working notes: decisions, findings, open risks |

## Using it

Prerequisites: Terraform, an AWS login (`aws sso login`), an existing key pair, and BYOL license files for FortiManager and
FortiAnalyzer in `terraform/licenses/` (`fmgr_license.lic`, `faz_license.lic`). FortiGates can be PAYG, BYOL or FortiFlex.

```
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit: passwords, key pair, admin source CIDRs, license paths
terraform init
terraform plan
terraform apply
```

If your shell exports `AWS_ACCESS_KEY_ID` and `AWS_SESSION_TOKEN` from an earlier session, they override a fresh SSO login.
Unset them (`unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`) and keep `AWS_PROFILE`.

Useful variables: `license_type` (payg, byol or fortiflex), `site_a_ssh_forwards` and `site_b_ssh_forwards`,
`tgw_cidr_blocks`, `enable_spoke_instances`.

`terraform/terraform.tfvars`, state, licenses and FortiGate config backups are excluded by `.gitignore`.

### FortiGate bootstrap through S3

A FortiGate BYOL license file is about 14 KB and EC2 user-data is limited to 16 KB, so the FortiGates boot from S3. User-data is a
small JSON (`bucket`, `region`, `config`, `license`) and each unit's config (`fgt-config.tpl`) and `.lic` file are objects in a
private per-site bucket, read through the instance profile. An S3 gateway endpoint on the public route table lets the secondary
(no public address on port1) reach the bucket at first boot. With `license_type = "byol"` set `primary_license_file` and
`secondary_license_file` in each site block; with payg or fortiflex no license object is created.

### Licensing with FortiFlex

Set `license_type = "fortiflex"` (BYOL image, units boot unlicensed with the full config). After the apply, license the units:

```
scripts/apply_fortiflex.py              # dry run: shows serials and addresses (uses /etc/ssl/cert.pem if Python has no CA bundle)
scripts/apply_fortiflex.py --execute    # tokens for all six units; FortiGates are licensed through the REST API
scripts/apply_fortiflex.py stop --execute   # stop the entitlements after a destroy
```

The FortiFlex username, password and entitlement serial numbers come from `terraform/terraform.tfvars` (`fortiflex_username`,
`fortiflex_password`, `fortigate_sns`, `fortimanager_sn`, `fortianalyzer_sn`). FortiManager and FortiAnalyzer tokens are
applied through JSON-RPC (`exec /sys/vm/license`, an unverified path); if FortiManager rejects it, the token is printed
for `execute vm-license <token>`.

### Licensing: use PAYG

`license_type = "payg"` is the setting that works. On FortiOS 8.0.1 (build 0245) BYOL and FortiFlex units stayed at
`License Status: Pending` with the FortiGuard update daemon logging `SETUP failed` (`no res header`), even though FortiCare showed
the serial valid. PAYG units validate immediately. The BYOL and FortiFlex code paths remain but are not known to work.

### FortiGuard and the secondary

Only the primary's port1 has the cluster EIP, so the secondary has no internet path through port1. No interface is selected
for FortiGuard, and port4 has no internet path: in testing, all four PAYG units validated their license with the defaults, so
the secondary evidently uses the HA management interface (port3 and its EIP).

### HA management security group

The ha-mgmt security group (on port3) allows TCP 443, TCP 22 and ICMP **only from `management_cidr_sg`**, and all traffic from
the inspection VPC CIDR for the heartbeat and sync. It allows all traffic from the VPC, not just the peer's address. The standby's heartbeat
could leave through port1 with a port1 source address, and the primary ignores heartbeat that does not come from the
configured peer, which split the cluster.

### Running without management EIPs

`enable_fgt_management_eip = false` drops the EIPs on the FortiGate port3 interfaces (for example when the customer reaches the
inspection VPC over Direct Connect). Without an EIP the units have no independent path to the public EC2 API, which the FGCP
reference calls critical for failing over AWS SDN. In that case deploy the EC2 interface endpoint (Private DNS) in both ha-mgmt
subnets, as the reference describes. DNS goes to the AWS resolver. Things to watch for:

- **Port3's gateway.** The HA-mgmt gateway points out the ha-mgmt subnet's route table (an IGW route). With no EIP that path
  goes nowhere, which only matters for the EC2 API and licensing.
- **FortiManager and FortiAnalyzer licensing.** FortiFlex activation needs outbound internet from FMG and FAZ, and they also have
  public IP switches (`enable_fortimanager_public_ip`, `enable_fortianalyzer_public_ip`). If the customer wants those private
  too, they need a NAT gateway or proxy in the management VPC, or offline license files.
- **The script.** `scripts/apply_fortiflex.py` reaches FMG and FAZ at their public addresses and the FortiGates at their
  management EIPs. Without public addresses it has to run from a host with private access to the management VPC.

### Checking the data path

On a site's primary FortiGate:

```
diag sys gre list                         # GRE tunnels exist
execute ping 169.254.6.2                  # TGW BGP peer, east
get router info bgp summary               # four neighbors Established
get router info routing-table all         # local spokes over BGP, remote spokes via the IPsec tunnel
diag vpn ike gateway list                 # IPsec up
get system ha status                      # HA sync
```

Then ping between spoke instances (east, west, and across the sites), and check that the test instances reach the internet.

## Status and caveats

- **The Connect (GRE) data path is new and unverified on a unit.** It needs BGP over GRE with multihop, the default route
  originated by the FortiGate, and a transport attachment with no route table association. Any of these may need adjusting.
- **Port3 as the combined HA interface follows the FGCP reference** (one ENI for heartbeat, sync and HA management, public
  subnet, EIP), and port4 (VRF 1, `dedicated-to management`, no EIP) is the layout that registered both sites in FortiManager
  and FortiAnalyzer before. Not yet verified together: that port3's EIP stays put on failover, and `vrf-select 1` on the
  FortiAnalyzer setting.
- **The inter-site GRE tunnels are new and unverified on a unit.** Check `key-inbound`/`key-outbound` are accepted on
  `gre-tunnel`, the `/32` on the IPsec interface, the 1350 MTU. The per-peer `prefix-list-out` must list `0.0.0.0/0` as well as the remote
  prefix, or the default route is filtered ("default not sent") and the spokes lose their return path.
- **HA does not cover GRE.** The Connect peers point at the primary FortiGate's port2 address, so a failover does not move the
  tunnels. The cluster EIP and IPsec do fail over.
- **Policy-based IPsec and per-customer VRFs are not built.** A multi-customer variant (a VRF, a GRE tunnel and an IPsec tunnel
  per customer) has been discussed but is not in this code.
- **Open security group on port1.** The port1 SG allows all inbound traffic by default (`public_ingress_cidrs`); access is
  controlled by the FortiGate policies. Restrict it before using this anywhere real.
- **One password for the demo.** The deployed demo uses a single password for every secret to keep it simple (not in this repo).
  Do not do that outside a demo.
- **FortiManager may need `fgfm-allow-vm`** (`config system global`) to accept FortiGate VMs, depending on its license.
- FortiGate-VM AMIs are matched by FortiOS version string (`8.0` resolves to 8.0.1 in us-west-2).
