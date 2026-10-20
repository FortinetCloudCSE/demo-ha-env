# CLAUDE.md

Context for Claude Code. This is a custom Terraform build for a specific customer demo (repo `demo-ha-env`).
It was moved here from `fortinet-ui-terraform`; it is not part of that repo.

## Goal (from the user)

Two FortiGate FGCP HA pairs, each in its own inspection VPC, joined by IPsec VPN. Each pair has
east/west workload VPCs attached to its own TGW, sitting behind the pair. One shared management VPC
holds FortiManager + FortiAnalyzer. Every FortiGate has a port3 HA-management interface with an EIP (GUI/SSH) and a port4
multi-VPC ENI in the management VPC (no EIP) used only for FortiManager and FortiAnalyzer. Customers (east, west) are
isolated end to end by GRE tunnels and firewall policy, not VRFs.

## Decisions already made (user confirmed; do not re-ask)

- Single AWS account and region. One shared management VPC (multi-VPC ENIs must be same account and same AZ).
- One TGW per site. East/west spokes attach to the site's TGW. Inter-site traffic must use the IPsec tunnel.
- IPsec: cluster EIP to cluster EIP, IKEv2, route-based, static routes (no BGP between the sites), with one GRE tunnel per
  customer inside it (`gre-east-x`, `gre-west-x`). Cluster EIPs are allocated in the root module so each site can reference
  the other's address.
- Spokes egress through the HA pair from the start (default route to the inspection attachment). No two-stage
  bootstrap through the management VPC. The management VPC has its own IGW and is not attached to either TGW.
- FortiManager, FortiAnalyzer and FortiGate AMIs are looked up dynamically by version string matched against
  the AMI name (same approach as `terraform-modules/aws_management_vpc`):
  - `FortiManager*VM64-AWS *(${fortimanager_os_version}*) GA*`
  - `FortiAnalyzer*VM64-AWS *(${fortianalyzer_os_version}*) GA*`
  - FortiGate (verified): `FortiGate-VM64-AWS build*(${fortios_version}*)*` for BYOL and
    `FortiGate-VM64-AWSONDEMAND build*(${fortios_version}*)*` for PAYG. Owner `679593333241`.

## Layout

All Terraform lives under `terraform/` (run terraform from there). `content/` is the Hugo site, `scripts/` and
`generate_network_diagram.sh` stay at the root. Paths below are relative to `terraform/` unless they start with `content/` or `scripts/`.

- `main.tf` provider, FortiGate AMI lookup. `management.tf` management VPC, SGs, FMGR/FAZ AMIs and instances.
- `sites.tf` cluster EIPs plus `module.site_a` / `module.site_b`. `variables.tf`, `outputs.tf`, `terraform.tfvars.example`.
- `config_templates/` FMGR/FAZ user-data, copied from `fortinet-ui-terraform/terraform/aws/existing_vpc_resources`.
- `modules/site/` one site: `inspection_vpc.tf` (VPC, subnets, route tables, EC2 API endpoint), `tgw_spokes.tf` (TGW,
  attachments, east/west VPCs, optional SSM test instances), `fortigate.tf` (SGs, IAM, ENIs, instances, EIPs),
  `templates/fgt-config.tpl` (HA, IPsec, policies, FMG/FAZ registration, `${extra_config}` hook), `outputs.tf`.
- `templates/ssh-forwards.tpl` (root) renders per-site SSH VIPs on the cluster EIP (address objects, `<name>-ssh` services,
  `vip-ssh-<site>-<name>`, policies 10+). `sites.tf` passes it to each module as `extra_config` when the site's forward list
  is non-empty. Vars: `ssh_admin_sources` (map of address-object name to CIDR), `site_a_ssh_forwards`, `site_b_ssh_forwards`
  (`{name, port, spoke}`, spoke = east or west). Spoke test instances are pinned at `spoke_host_ip` (default 4, the first
  usable host) in their AZ1 workload subnet, so the VIP target is computed in `sites.tf` with `cidrhost()` and does not depend
  on the instances (which would be a cycle). Pinning replaces the DHCP addresses, so the spoke instances get rebuilt on the
  next apply (east/west are now .132 in site_a/site_b 10.x.y.0/24 spokes instead of the old DHCP IPs).
- Inspection /21 is split into eight /24s: public, private, ha-mgmt, tgw (each AZ1/AZ2). Spoke /24s into four /26s.
- Interfaces: port1 public (cluster EIP, IPsec), port2 private (TGW side), port3 heartbeat + config sync + HA-mgmt in a
  public ha-mgmt subnet with an EIP per unit (the FGCP reference design; EC2 API goes out port3, no VPC endpoint), port4
  multi-VPC ENI in the management VPC with NO EIP, VRF 1, `dedicated-to management`, `allowaccess fgfm` only
  (FortiManager and FortiAnalyzer traffic only; no FortiGuard on it). See "Management design" at the end of this file.

## Data path: TGW Connect (GRE), no inspection VPC routing (deployed and verified on units)

Each spoke (east, west) has its own Connect attachment and one Connect peer to the PRIMARY FortiGate port2 IP (`modules/site/connect.tf`).
The inspection VPC attachment still exists, but only as the Connect transport (AWS requires one); no TGW route table is
associated with it, nothing propagates to it and no route targets it. The old shared spokes/inspection TGW route tables, the
spokes default route and the inspection-VPC TGW-subnet route to the master ENI are gone.
- Per spoke two TGW route tables: `spoke_rt` (associated with the spoke attachment, learns BGP routes from the Connect attachment)
  and `connect_rt` (associated with the Connect attachment, learns the spoke CIDR). TGW CIDR block per site in root
  `tgw_cidr_blocks` (10.254.1.0/24 site_a, 10.254.2.0/24 site_b); GRE outer TGW address is host 10 (east) / 11 (west).
  Inside /29s: east 169.254.6.0/29, west 169.254.7.0/29 (FortiGate .1, TGW BGP peers .2/.3). Connect needs BGP, static is not supported.
- FortiGate (`fgt-config.tpl`): `gre-east`/`gre-west` on port2, eBGP AS 65001 to the TGW (64512), two neighbors per peer with
  `capability-default-originate` (that is how the spokes get internet egress) and the remote-site CIDRs as `network` statements. The
  IPsec tunnel to the other site is unchanged. Policies use the GRE interfaces (see the isolation section at the end).
- SSH VIPs egress via `gre-<spoke>` with `nat disable` (the GRE inside addresses are not routable from the spokes), so the spoke SG
  allows SSH from anywhere; the spokes have no IGW and the FortiGate policy gates access.
- HA: GRE local-gw is per unit and the Connect peer points at the primary only, so failover does not move GRE. Unverified on a unit:
  BGP over GRE (multihop), default-originate, MTU 1400, the transport attachment needing no route table association.

## Status (end of 2026-10-17)

Repo: github.com/FortinetCloudCSE/demo-ha-env (fresh single commit). All Terraform is in `terraform/`; the user runs plan/apply/destroy in their own terminal (this assistant's shell has
stale exported AWS keys). At the end of the day the stack was being destroyed; the next step is a fresh apply.

Verified on live units (two full deployments): HA on both sites; four BGP sessions per site with `default sent`; SSH VIPs;
spoke internet egress; IPsec up (needs policies 8/9); east-to-east and west-to-west across the sites; east-to-west blocked and
logged; FortiManager registration (authorize from the FortiGate side); PAYG license valid on all units; first-login dialogs:
"What's New" gone (hidden `gui-ignore-release-overview-version "8.0"`), FortiConverter prompt hidden by
`diagnose sys forticonverter set-prompt-visibility hidden` in the template (the `system global` forticonverter settings do not control the GUI dialog; verified 2026-10-19: no dialogs at first login).

Facts worth keeping:
- `fortios_version` is matched as a prefix against the AMI name: `8.0` resolves to 8.0.1 in us-west-2. Use `license_type = "payg"`
  (BYOL and FortiFlex stayed `Pending` on 8.0.1). SG descriptions cannot contain apostrophes. The keypair must exist.
- Management IPs are pinned: `fortimanager_host_ip`, `fortianalyzer_host_ip`, `fortigate_mgmt_host_ips` (port4 per site,
  `[AZ1 primary, AZ2 secondary]`, default site_a 20, site_b 21). `terraform_data.management_ip_check` fails the plan on collisions.
- `management_cidr_sg` lists who may reach the port3 GUI/SSH; `203.0.113.10/32` (TEST-NET-3) is the placeholder in the example.
- HA group name is `acme-demo-site-a` / `-b` (cluster ID default 0). The port1 SG is open to `public_ingress_cidrs` (default
  `0.0.0.0/0`); the FortiGate policies (the `ssh_admin_sources` address objects) gate access.
- Changing `fgt-config.tpl` changes the user-data and replaces all four FortiGates on the next apply.
- `generate_network_diagram.sh` (repo root, runs terraform in `terraform/`) writes `diagram/network_diagram.{svg,md}`;
  works under macOS bash 3.2. It has not been run since the port3/port4 redesign.

## Open risks to verify

1. Not yet confirmed on a unit: `vrf-select 1` under `log fortianalyzer setting`, and that port3's EIP stays put after a failover.
2. Failover itself is untested. The Connect peers point at the primary only, so GRE to the TGW does not follow a failover (by design).
3. The cause of the site B FortiManager "cannot authorize" problem was never found; it cleared when authorizing from the FortiGate.
4. (Resolved 2026-10-19) The "Migrate Config with FortiConverter" first-login dialog is hidden by the diagnose command in the template, before the port4 stanza (nothing after `yend` runs).
5. Spoke test instances need the HA pair up and forwarding (SSM and package access go through the FortiGates).

## Next steps

1. Fresh apply, then the first checks: `get system ha status` and `diagnose sys ha checksum cluster`; `show system central-management`
   (specify, port4, vrf-select 1); `get router info routing-table all` (VRF 1 route to the management VPC via port4);
   `get router info bgp neighbors 169.254.6.2` (`default sent`); `get vpn ipsec tunnel summary` (`1/1`); the EIPs on the port3 ENIs.
2. Add a "Bootstrap and troubleshooting lessons" part to `content/9_What_We_Learned`: silent bootstrap failures (compare `show`
   with the template or use `diagnose debug config-error-log read`), sniffer filters must match the post-NAT packet,
   `vdom-exception`, NAT-T on UDP 4500, the 16 KB user-data limit and the S3 bootstrap, multi-VPC ENIs need the same AZ,
   `fgfm-allow-vm`, and the first-login settings.
3. Failover test (stop the primary).
4. Hugo CI: copy `config.toml`, `Jenkinsfile`, `package.json` and `layouts/` from `../FGCP-in-AWS`; replace the Lucidchart
   placeholders (search `TODO: replace` in `content/`).

## Reference sources

- `../FGCP-in-AWS` is the FGCP workshop docs only (no Terraform). `../Autoscale-Simplified-Template` has the
  TGW and spoke patterns plus a blue/green inspection stack. `../terraform-modules` holds the module code
  (`aws_management_vpc` for the FMGR/FAZ AMI lookup). `../fortinet-ui-terraform/terraform/aws/ha_pair` is the
  closest existing HA pair template.

## Preferences

- Do not commit or push without an explicit instruction; do not run commands on the live FortiGates unless asked (give the commands
  and ask for the output). Terraform plan/apply/destroy are run by the user.
- Use `terraform fmt` after edits. Keep comment density and style consistent with the existing files.

## Customer isolation: GRE tunnels, not VRFs (2026-10-17)

East and west are isolated by tunnels and policy, with no VRFs. Per site: `gre-east`/`gre-west` to the TGW (Connect) and
`gre-east-x`/`gre-west-x` through the IPsec tunnel to the other site (GRE keys 10/20; IPsec interface /32s in
169.254.100.0/30, inside /30s 169.254.10.0/30 and 169.254.20.0/30, site_a takes host 1, site_b host 2; see the end of
`modules/site/connect.tf`). Policies 1-7 in `fgt-config.tpl` are per customer plus a logged `deny-east-west`; SSH forwards start at 10.
Each TGW BGP peer has a `prefix-list-out` with only its customer's remote CIDR.

VRFs were tried by hand on a live unit (FortiOS 8.0.1) and dropped. Findings: `set vrf N` on the GRE interface works; a BGP neighbor
joins the VRF through `set interface`/`set update-source`; the GRE underlay needs a static route with `set vrf N` to the TGW CIDR.
But sessions are VRF-scoped: internet egress through port1 and the SSH VIPs (cross-VRF via leaked static routes) fail with `no
session matched` on the reply. VRFs would need an egress interface per customer (port5/port6 + EIP) or VDOMs.

Unverified: the inter-site GRE traffic (BGP-side GRE, the /32 on the IPsec interface and MTU 1350 are in place on a unit; ping across the sites untested).
Found on a unit: `prefix-list-out` filters the default-originate route too ("default not sent"), so each list must include `0.0.0.0 0.0.0.0`.

## Management design (2026-10-17)

Final layout after several iterations; the history matters because each earlier variant failed for a reason.
- **port3 is the HA-mgmt interface** (`config system ha` / `ha-mgmt-interface`, gateway = the unit's own subnet gateway), also
  `hbdev`. Public ha-mgmt subnet + EIP per unit. The FGCP reference says failover moves only the cluster EIP (on port1's
  primary IP) and route targets; the EIP on the HA mgmt port stays with the unit. When the management ENI (then port4) was
  outside `config system ha` and carried the EIPs, failover moved them.
- **port4 cannot be the HA-mgmt interface**: FortiOS then refuses it as the source interface for FortiGuard / FortiManager /
  FortiAnalyzer (`set interface port4` -> `entry not found in datasource`), the stanza is dropped (the whole FortiAnalyzer
  block was lost) and traffic to 10.99.0.0/24 follows the port1 default route.
- **port4** is an ordinary interface in `vrf 1`, then `dedicated-to management` LAST in the bootstrap. FortiOS prompts for a
  reboot, which aborts the init script, so the template ends with:
  ```
  config system interface
  edit port4
  set vrf 1
  set dedicated-to management
  next
  yend
  ```
  (`yend` answers the prompt and ends the stanza). FortiManager/FortiAnalyzer use `interface-select-method specify`,
  `interface port4`, `vrf-select 1` (central-management confirmed with this in the first deployment; the FortiAnalyzer
  `vrf-select` is untested). A static route in VRF 1 to the management VPC CIDR via the port4 gateway is needed because the
  secondary's port4 is in a different subnet from FortiManager.
- **FortiGuard**: no interface selection (port4 has no internet). All four PAYG units validated with the defaults.
- A VPC peering or a TGW attachment from the management VPC to the inspection VPCs were discussed as alternatives (FortiGate
  route 10.99.0.0/24 via port2) and not built.
- The "sessions are VRF-scoped" VRF finding does not affect VRF 1 here: port4's traffic is local-out / local-in on the FortiGate.
