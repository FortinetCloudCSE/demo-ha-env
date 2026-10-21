#====================================================================================================
# TGW CONNECT (GRE): one Connect attachment + peer per spoke (east, west)
#   The inspection VPC attachment is only the transport. Per spoke there are two TGW route tables:
#     spoke_rt   : associated with the spoke VPC attachment; learns the default route and the remote-site
#                  CIDRs from the FortiGate over BGP (Connect propagation)
#     connect_rt : associated with the Connect attachment; learns only that spoke's CIDR (propagation),
#                  which is what the FortiGate receives over BGP
#   The Connect peer targets the PRIMARY FortiGate port2 IP only, so an HA failover does not move GRE.
#   Inside (BGP) CIDRs: the FortiGate is the first address, the TGW BGP peers are the second and third.
#====================================================================================================
locals {
  connect_inside_cidr = { east = "169.254.6.0/29", west = "169.254.7.0/29" }
  # GRE outer address of the TGW side, one host per spoke from the first TGW CIDR block
  connect_tgw_addr = { east = cidrhost(var.tgw_cidr_blocks[0], 10), west = cidrhost(var.tgw_cidr_blocks[0], 11) }
  connect_bgp = {
    for k, c in local.connect_inside_cidr : k => {
      fgt_ip  = cidrhost(c, 1)
      tgw_ip1 = cidrhost(c, 2)
      tgw_ip2 = cidrhost(c, 3)
    }
  }
}

# The transport attachment must be associated with some route table before the Connect attachments can be associated.
# This table stays empty: no propagation, no routes, so nothing is ever routed through the inspection attachment.
resource "aws_ec2_transit_gateway_route_table" "transport" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "${local.prefix}-transport-tgw-rtb" }
}
resource "aws_ec2_transit_gateway_route_table_association" "transport" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.transport.id
}

resource "aws_ec2_transit_gateway_connect" "spoke" {
  for_each                                        = local.spokes
  transport_attachment_id                         = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "${local.prefix}-${each.key}-connect" }
}

resource "aws_ec2_transit_gateway_connect_peer" "spoke" {
  for_each                      = local.spokes
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.spoke[each.key].id
  peer_address                  = aws_network_interface.primary_port2.private_ip
  transit_gateway_address       = local.connect_tgw_addr[each.key]
  inside_cidr_blocks            = [local.connect_inside_cidr[each.key]]
  bgp_asn                       = var.fortigate_bgp_asn
  tags                          = { Name = "${local.prefix}-${each.key}-connect-peer" }
}

resource "aws_ec2_transit_gateway_route_table" "spoke_rt" {
  for_each           = local.spokes
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "${local.prefix}-${each.key}-spoke-tgw-rtb" }
}
resource "aws_ec2_transit_gateway_route_table" "connect_rt" {
  for_each           = local.spokes
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  tags               = { Name = "${local.prefix}-${each.key}-connect-tgw-rtb" }
}

resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  for_each                       = local.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_rt[each.key].id
}
resource "aws_ec2_transit_gateway_route_table_association" "connect" {
  for_each                       = local.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_connect.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.connect_rt[each.key].id
  depends_on                     = [aws_ec2_transit_gateway_route_table_association.transport]
}

# spoke CIDR -> the FortiGate (connect_rt); BGP-learned default and remote-site CIDRs -> the spoke (spoke_rt)
resource "aws_ec2_transit_gateway_route_table_propagation" "spoke_to_connect" {
  for_each                       = local.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.connect_rt[each.key].id
}
resource "aws_ec2_transit_gateway_route_table_propagation" "connect_to_spoke" {
  for_each                       = local.spokes
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_connect.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spoke_rt[each.key].id
}

#====================================================================================================
# INTER-SITE GRE (inside the IPsec tunnel): one GRE tunnel per customer to the other site's FortiGate
#   The IPsec tunnel interface carries a /32 address on each side; each GRE tunnel runs between those
#   addresses and is told apart by its GRE key. Each customer has its own inside /30. Site 1 takes the
#   first host of every /30, site 2 the second. East traffic only uses gre-east-x, west only gre-west-x.
#====================================================================================================
locals {
  intersite_tunnel_cidr = "169.254.100.0/30"
  intersite_gre_key     = { east = 10, west = 20 }
  # one VRF per customer on the FortiGate; the tunnels to the TGW and to the other site and their routes live in it
  customer_vrf          = { east = 10, west = 20 }
  intersite_inside_cidr = { east = "169.254.10.0/30", west = "169.254.20.0/30" }

  intersite_tunnel_local  = cidrhost(local.intersite_tunnel_cidr, var.site_index)
  intersite_tunnel_remote = cidrhost(local.intersite_tunnel_cidr, 3 - var.site_index)
  intersite_inside = {
    for k, c in local.intersite_inside_cidr : k => {
      local  = cidrhost(c, var.site_index)
      remote = cidrhost(c, 3 - var.site_index)
    }
  }
}
