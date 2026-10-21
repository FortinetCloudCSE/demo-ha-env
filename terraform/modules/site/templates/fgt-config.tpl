config system global
set hostname ${hostname}
set admintimeout 60
# no FortiConverter question or config upload at first login
set forticonverter-integration disable
set forticonverter-config-upload disable
end

config system admin
edit admin
set password ${admin_password}
# hidden option: no "What's New" dialog at first login (the value is the major release, not 8.0.1)
set gui-ignore-release-overview-version "8.0"
next
end

config system interface
edit port1
set mode static
set ip ${port1_ip} ${port1_mask}
set allowaccess ping
set alias untrusted
next
edit port2
set mode static
set ip ${port2_ip} ${port2_mask}
set allowaccess ping
set alias trusted
next
edit port3
set mode static
set ip ${port3_ip} ${port3_mask}
set allowaccess ping https ssh
set alias ha-mgmt
next
edit port4
set mode static
set vrf 1
set ip ${port4_ip} ${port4_mask}
set allowaccess fgfm
set alias management
next
end

# ENI IPs are pinned in Terraform and set statically: a DHCP lease on the standby unit did not survive a reboot
config router static
edit 1
set device port1
set gateway ${port1_gateway}
next
# FortiManager and FortiAnalyzer are in the management VPC, reached through port4 in VRF 1 (the secondary's port4 is in a
# different subnet from them, so it needs this route rather than a connected network)
edit 2
set dst ${cidrhost(management_vpc_cidr, 0)} ${cidrnetmask(management_vpc_cidr)}
set gateway ${port4_gateway}
set device port4
set vrf 1
next
# the TGW GRE addresses (outer tunnel endpoints) are reached through the private subnet, not the default route
%{ for i, cidr in tgw_cidrs ~}
edit ${10 + i}
set dst ${cidr}
set gateway ${port2_gateway}
set device port2
next
%{ endfor ~}
end

config system vdom-exception
edit 1
set object system.interface
next
edit 2
set object router.static
next
end

config system ha
set group-name ${ha_group_name}
set mode a-p
set hbdev port3 50
set session-pickup enable
set ha-mgmt-status enable
config ha-mgmt-interface
edit 1
set interface port3
set gateway ${port3_gateway}
next
end
set override disable
set priority ${ha_priority}
set password ${ha_password}
set unicast-hb enable
set unicast-hb-peerip ${ha_peer_ip}
end

config system dns
set primary 169.254.169.253
set protocol cleartext
end

config vpn ipsec phase1-interface
edit ${tunnel_name}
set interface port1
set ike-version 2
set peertype any
set net-device disable
set proposal aes256-sha256
set dhgrp 14
set nattraversal enable
set remote-gw ${peer_public_ip}
set psksecret ${ipsec_psk}
set dpd on-idle
set dpd-retrycount 3
set dpd-retryinterval 5
next
end

config vpn ipsec phase2-interface
edit ${tunnel_name}
set phase1name ${tunnel_name}
set proposal aes256-sha256
set dhgrp 14
set auto-negotiate enable
set keepalive enable
set src-subnet 0.0.0.0 0.0.0.0
set dst-subnet 0.0.0.0 0.0.0.0
next
end

# GRE to the TGW Connect peers (one per spoke); the inside /29 carries two eBGP sessions per peer
config system gre-tunnel
%{ for c in connect_peers ~}
edit gre-${c.name}
set interface port2
set local-gw ${port2_ip}
set remote-gw ${c.tgw_addr}
next
%{ endfor ~}
end

config system interface
%{ for c in connect_peers ~}
edit gre-${c.name}
set ip ${c.fgt_ip} 255.255.255.255
set remote-ip ${c.tgw_ip1} 255.255.255.248
set allowaccess ping
set mtu-override enable
set mtu 1400
set vrf ${c.vrf}
next
%{ endfor ~}
end

# the IPsec tunnel interface gets a /32 on each side; the inter-site GRE tunnels run between these addresses
config system interface
edit ${tunnel_name}
set ip ${intersite_tunnel_local} 255.255.255.255
set remote-ip ${intersite_tunnel_remote} 255.255.255.255
next
end

config system gre-tunnel
%{ for c in intersite ~}
edit gre-${c.name}-x
set interface ${tunnel_name}
set local-gw ${intersite_tunnel_local}
set remote-gw ${intersite_tunnel_remote}
set key-outbound ${c.key}
set key-inbound ${c.key}
next
%{ endfor ~}
end

config system interface
%{ for c in intersite ~}
edit gre-${c.name}-x
set ip ${c.fgt_ip} 255.255.255.255
set remote-ip ${c.peer_ip} 255.255.255.252
set allowaccess ping
set mtu-override enable
set mtu 1350
set vrf ${c.vrf}
next
%{ endfor ~}
end

# each customer reaches the other site only through its own GRE tunnel inside the IPsec tunnel
# (after the interfaces above: a route cannot name a device that does not exist yet)
config router static
%{ for i, c in intersite ~}
edit ${20 + i}
set dst ${c.remote_cidr}
set device gre-${c.name}-x
set vrf ${c.vrf}
next
%{ endfor ~}
# each customer lives in its own VRF (east 10, west 20), so each VRF needs its own routes (after the gre interfaces exist):
# - the GRE underlay: the TGW addresses through port2 and the remote tunnel address through the IPsec interface
# - a default route out port1 for internet egress and the SSH VIPs
# - and in VRF 0 (where port1 is) the way back to the customer's spokes through its GRE tunnel
%{ for pi, c in connect_peers ~}
%{ for ti, cidr in tgw_cidrs ~}
edit ${30 + 10 * pi + ti}
set dst ${cidr}
set gateway ${port2_gateway}
set device port2
set vrf ${c.vrf}
next
%{ endfor ~}
edit ${50 + pi}
set dst ${intersite_tunnel_remote} 255.255.255.255
set device ${tunnel_name}
set vrf ${c.vrf}
next
edit ${60 + pi}
set gateway ${port1_gateway}
set device port1
set vrf ${c.vrf}
next
edit ${70 + pi}
set dst ${c.local_cidr}
set device gre-${c.name}
set vrf 0
next
%{ endfor ~}
end

# each TGW peer only gets the default route and the remote prefix of its own customer
# (the default must be listed: an outbound prefix-list also filters the default-originate route)
config router prefix-list
%{ for c in connect_peers ~}
edit pl-${c.name}-out
config rule
edit 1
set prefix ${cidrhost(c.remote_cidr, 0)} ${cidrnetmask(c.remote_cidr)}
next
edit 2
set prefix 0.0.0.0 0.0.0.0
next
end
next
%{ endfor ~}
end

# BGP: the TGW learns the remote-site spokes and a default route from here, the FortiGate learns the local spokes
config router bgp
set as ${fgt_asn}
set router-id ${port1_ip}
config neighbor
%{ for c in connect_peers ~}
edit ${c.tgw_ip1}
set remote-as ${tgw_asn}
set ebgp-enforce-multihop enable
set soft-reconfiguration enable
set capability-default-originate enable
set prefix-list-out pl-${c.name}-out
set interface gre-${c.name}
set update-source gre-${c.name}
next
edit ${c.tgw_ip2}
set remote-as ${tgw_asn}
set ebgp-enforce-multihop enable
set soft-reconfiguration enable
set capability-default-originate enable
set prefix-list-out pl-${c.name}-out
set interface gre-${c.name}
set update-source gre-${c.name}
next
%{ endfor ~}
end
config network
%{ for i, c in intersite ~}
edit ${1 + i}
set prefix ${c.remote_cidr}
next
%{ endfor ~}
end
end

config firewall address
edit local-east
set subnet ${local_east_cidr}
next
edit local-west
set subnet ${local_west_cidr}
next
edit remote-east
set subnet ${remote_east_cidr}
next
edit remote-west
set subnet ${remote_west_cidr}
next
edit ipsec-local-ip
set subnet ${intersite_tunnel_local} 255.255.255.255
next
edit ipsec-peer-ip
set subnet ${intersite_tunnel_remote} 255.255.255.255
next
end

# customers are isolated by policy: each customer has its own policies and its own inter-site tunnel,
# and the last policy denies east <-> west explicitly so the attempts show up in the logs
config firewall policy
edit 1
set name east-to-internet
set srcintf gre-east
set dstintf port1
set srcaddr local-east
set dstaddr all
set action accept
set schedule always
set service ALL
set nat enable
set skip-vrf-match enable
set logtraffic all
next
edit 2
set name west-to-internet
set srcintf gre-west
set dstintf port1
set srcaddr local-west
set dstaddr all
set action accept
set schedule always
set service ALL
set nat enable
set skip-vrf-match enable
set logtraffic all
next
edit 3
set name east-to-remote-east
set srcintf gre-east
set dstintf gre-east-x
set srcaddr local-east
set dstaddr remote-east
set action accept
set schedule always
set service ALL
set logtraffic all
next
edit 4
set name remote-east-to-east
set srcintf gre-east-x
set dstintf gre-east
set srcaddr remote-east
set dstaddr local-east
set action accept
set schedule always
set service ALL
set logtraffic all
next
edit 5
set name west-to-remote-west
set srcintf gre-west
set dstintf gre-west-x
set srcaddr local-west
set dstaddr remote-west
set action accept
set schedule always
set service ALL
set logtraffic all
next
edit 6
set name remote-west-to-west
set srcintf gre-west-x
set dstintf gre-west
set srcaddr remote-west
set dstaddr local-west
set action accept
set schedule always
set service ALL
set logtraffic all
next
# FortiOS only negotiates a route-based IPsec tunnel when a policy references the tunnel interface. The GRE tunnels are
# originated by the FortiGate itself and never hit a policy, so these two policies exist to bring the tunnel up. They only
# match the two tunnel endpoint addresses and carry nothing else.
edit 8
set name ipsec-tunnel-out
set srcintf port2
set dstintf ${tunnel_name}
set srcaddr ipsec-local-ip
set dstaddr ipsec-peer-ip
set action accept
set schedule always
set service PING
next
edit 9
set name ipsec-tunnel-in
set srcintf ${tunnel_name}
set dstintf port2
set srcaddr ipsec-peer-ip
set dstaddr ipsec-local-ip
set action accept
set schedule always
set service PING
next
edit 7
set name deny-east-west
set srcintf gre-east gre-west gre-east-x gre-west-x
set dstintf gre-east gre-west gre-east-x gre-west-x
set srcaddr all
set dstaddr all
set action deny
set schedule always
set service ALL
set logtraffic all
next
end

${extra_config}
%{ if fortimanager_ip != "" ~}
config system central-management
set type fortimanager
set fmg ${fortimanager_ip}
set interface-select-method specify
set interface port4
set vrf-select 1
end
%{ endif ~}

%{ if fortianalyzer_ip != "" ~}
config log fortianalyzer setting
set status enable
set server ${fortianalyzer_ip}
set interface-select-method specify
set interface port4
set vrf-select 1
end
%{ endif ~}

%{ if license_type == "fortiflex" && fortiflex_token != "" ~}
exec vm-license ${fortiflex_token}
%{ endif ~}

# no "Migrate Config with FortiConverter" dialog at first GUI login (a diagnose setting, not part of the config)
diagnose sys forticonverter set-prompt-visibility hidden

# port4 goes dedicated-to management last: FortiOS prompts to reboot, so "yend" answers it and ends the stanza, and
# anything after this point in the script would not run. port4 is static (the ENI IP is pinned), has no EIP, and only
# carries FortiManager (fgfm) and FortiAnalyzer traffic in VRF 1. FortiGuard and licensing use the defaults.
config system interface
edit port4
set vrf 1
set dedicated-to management
next
yend
