#!/bin/bash

# Generate Network Diagram Script
# Creates an SVG network diagram and markdown documentation from the deployed Terraform state.
#
# Usage:
#   ./generate_network_diagram.sh              # writes ./diagram/network_diagram.{svg,md}
#   ./generate_network_diagram.sh -o <dir>     # write somewhere else
#
# Reads `terraform output -json` for addresses and ids, and `terraform console` for the CIDRs and
# naming inputs (so defaults in variables.tf are honored). Needs terraform and jq; no AWS calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/diagram"

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-o <output dir>]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

for tool in terraform jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found in PATH"; exit 1; }
done

cd "${SCRIPT_DIR}/terraform" || exit 1
mkdir -p "$OUTPUT_DIR"
SVG_FILE="${OUTPUT_DIR}/network_diagram.svg"
MD_FILE="${OUTPUT_DIR}/network_diagram.md"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "Reading terraform outputs..."
OUT=$(terraform output -json 2>/dev/null)
if [[ -z "$OUT" || "$OUT" == "{}" ]]; then
    echo "ERROR: no terraform outputs found. Run terraform apply first."
    exit 1
fi

echo "Reading configuration..."
# terraform console reads one expression per line, so keep this on a single line
CFG=$(echo 'jsonencode({ region = var.aws_region, az1 = var.availability_zone_1, az2 = var.availability_zone_2, prefix = "${var.cp}-${var.env}", mgmt = var.vpc_cidr_management, a = var.site_a, b = var.site_b, fgt_type = var.fortigate_instance_type, license = var.license_type, fmg_enabled = var.enable_fortimanager, faz_enabled = var.enable_fortianalyzer, spokes_enabled = var.enable_spoke_instances })' | terraform console 2>/dev/null | jq -r 'fromjson' 2>/dev/null)
if [[ -z "$CFG" ]]; then
    echo "ERROR: could not read variables via terraform console (run terraform init first)."
    exit 1
fi

c() { jq -r "$1" <<<"$CFG"; }
o() { jq -r "$1" <<<"$OUT"; }

REGION=$(c .region); AZ1="$(c .region)$(c .az1)"; AZ2="$(c .region)$(c .az2)"
PREFIX=$(c .prefix); MGMT_CIDR=$(c .mgmt)
FGT_TYPE=$(c .fgt_type); LICENSE=$(c .license)
FMG_ENABLED=$(c .fmg_enabled); FAZ_ENABLED=$(c .faz_enabled); SPOKES_ENABLED=$(c .spokes_enabled)
FGT_AMI=$(o '.fortigate_ami.value.name')

# subnet <cidr> <n> <size> -> n-th subnet of the given prefix size inside <cidr> (any base size, e.g. a /24 out of a /21)
subnet() {
    local base=${1%/*} n=$2 size=$3 a b c d
    IFS=. read -r a b c d <<<"$base"
    local ip=$(( (a << 24) + (b << 16) + (c << 8) + d + n * (2 ** (32 - size)) ))
    echo "$(( (ip >> 24) & 255 )).$(( (ip >> 16) & 255 )).$(( (ip >> 8) & 255 )).$(( ip & 255 ))/${size}"
}

# Per-site values, indexed by site key (a|b)
# bash 3.2 (macOS /bin/bash) has no associative arrays: store per-site values as NAME_a / NAME_b
setv() { printf -v "${1}_${2}" '%s' "$3"; }
getv() { local n="${1}_${2}"; printf '%s' "${!n}"; }
for s in a b; do
    setv INSP "$s" $(c ".$s.inspection_cidr"); setv EAST "$s" $(c ".$s.east_cidr"); setv WEST "$s" $(c ".$s.west_cidr")
    setv TGW "$s" $(o ".site_$s.value.transit_gateway_id"); setv VPC_INSP "$s" $(o ".site_$s.value.inspection_vpc_id")
    setv VPC_E "$s" $(o ".site_$s.value.spoke_vpc_ids.east"); setv VPC_W "$s" $(o ".site_$s.value.spoke_vpc_ids.west")
    setv SP_E "$s" $(o ".site_$s.value.spoke_instances.east // \"-\""); setv SP_W "$s" $(o ".site_$s.value.spoke_instances.west // \"-\"")
    setv P_ID "$s" $(o ".site_$s.value.primary.instance_id");   setv P_P1 "$s" $(o ".site_$s.value.primary.port1_ip")
    setv P_P3 "$s" $(o ".site_$s.value.primary.port3_ip");      setv P_MG "$s" $(o ".site_$s.value.primary.mgmt_ip")
    setv P_EIP "$s" $(o ".site_$s.value.primary.mgmt_eip // \"-\"")
    setv S_ID "$s" $(o ".site_$s.value.secondary.instance_id"); setv S_P1 "$s" $(o ".site_$s.value.secondary.port1_ip")
    setv S_P3 "$s" $(o ".site_$s.value.secondary.port3_ip");    setv S_MG "$s" $(o ".site_$s.value.secondary.mgmt_ip")
    setv S_EIP "$s" $(o ".site_$s.value.secondary.mgmt_eip // \"-\"")
    setv CEIP "$s" $(o ".cluster_eips.value.site_$s")
done
MGMT_VPC=$(o '.management.value.vpc_id')
FMG_IP=$(o '.management.value.fortimanager_ip // "-"');  FMG_EIP=$(o '.management.value.fortimanager_eip // "-"')
FAZ_IP=$(o '.management.value.fortianalyzer_ip // "-"'); FAZ_EIP=$(o '.management.value.fortianalyzer_eip // "-"')

#=============================================================================
# SVG helpers
#=============================================================================
SVG=""
add() { SVG+="$1"$'\n'; }
# rect x y w h fill stroke [dash]
rect() { add "<rect x=\"$1\" y=\"$2\" width=\"$3\" height=\"$4\" rx=\"6\" fill=\"$5\" stroke=\"$6\" stroke-width=\"1.5\"${7:+ stroke-dasharray=\"$7\"}/>"; }
# text x y size weight anchor fill content
text() { add "<text x=\"$1\" y=\"$2\" font-size=\"$3\" font-weight=\"$4\" text-anchor=\"$5\" fill=\"$6\">$7</text>"; }
# line x1 y1 x2 y2 stroke width [dash]
line() { add "<line x1=\"$1\" y1=\"$2\" x2=\"$3\" y2=\"$4\" stroke=\"$5\" stroke-width=\"$6\"${7:+ stroke-dasharray=\"$7\"}/>"; }

C_VPC="#f8fafc"; C_INSP="#eff6ff"; C_SUB="#ffffff"; C_MGMT="#fdf4ff"; C_TGW="#fef3c7"
C_BORDER="#64748b"; C_TEXT="#0f172a"; C_MUTED="#475569"; C_VPN="#dc2626"; C_MGMTLINE="#a855f7"; C_TGWLINE="#d97706"

# draw_site <key> <x-origin> <label>
draw_site() {
    local s=$1 x=$2 label=$3 y=70
    local W=640
    # Inspection VPC
    rect $x $y $W 400 "$C_INSP" "#2563eb"
    text $((x + 12)) $((y + 22)) 14 700 start "$C_TEXT" "$label inspection VPC  $(getv INSP "$s")  ($(getv VPC_INSP "$s"))"

    # AZ columns
    local az az_x az_name unit_label unit_id p1 p3 mg eip
    for az in 0 1; do
        az_x=$((x + 14 + az * 310))
        if [[ $az -eq 0 ]]; then
            az_name=$AZ1; unit_label="Primary"; unit_id=$(getv P_ID "$s"); p1=$(getv P_P1 "$s"); p3=$(getv P_P3 "$s"); mg=$(getv P_MG "$s"); eip=$(getv P_EIP "$s")
        else
            az_name=$AZ2; unit_label="Secondary"; unit_id=$(getv S_ID "$s"); p1=$(getv S_P1 "$s"); p3=$(getv S_P3 "$s"); mg=$(getv S_MG "$s"); eip=$(getv S_EIP "$s")
        fi
        rect $az_x $((y + 34)) 298 354 "$C_VPC" "$C_BORDER" "5,4"
        text $((az_x + 10)) $((y + 52)) 12 700 start "$C_MUTED" "$az_name"

        # FortiGate
        rect $((az_x + 10)) $((y + 62)) 278 108 "#dbeafe" "#1d4ed8"
        text $((az_x + 149)) $((y + 82)) 13 700 middle "$C_TEXT" "FortiGate $unit_label"
        text $((az_x + 149)) $((y + 98)) 10 400 middle "$C_MUTED" "$unit_id"
        text $((az_x + 20)) $((y + 118)) 10.5 400 start "$C_TEXT" "port1 public   $p1"
        if [[ $az -eq 0 ]]; then p2lbl="port2 private  gre-east, gre-west to TGW"; else p2lbl="port2 private  (no GRE; takes over on failover)"; fi
        text $((az_x + 20)) $((y + 133)) 10.5 400 start "$C_TEXT" "$p2lbl"
        text $((az_x + 20)) $((y + 148)) 10.5 400 start "$C_TEXT" "port3 HA-mgmt $p3  EIP $eip"
        text $((az_x + 20)) $((y + 163)) 10.5 400 start "$C_TEXT" "port4 mgmt (no EIP) $mg  (mgmt VPC)"

        # Subnets
        local i=0 name n
        for spec in "public:$az" "private:$((2 + az))" "ha-sync:$((4 + az))" "tgw:$((6 + az))"; do
            name=${spec%%:*}; n=${spec##*:}
            rect $((az_x + 10)) $((y + 182 + i * 48)) 278 40 "$C_SUB" "$C_BORDER"
            text $((az_x + 20)) $((y + 199 + i * 48)) 11 700 start "$C_TEXT" "$name subnet"
            text $((az_x + 20)) $((y + 214 + i * 48)) 10.5 400 start "$C_MUTED" "$(subnet "$(getv INSP "$s")" "$n" 24)"
            i=$((i + 1))
        done
    done

    # Cluster EIP strip
    rect $x $((y + 410)) $W 30 "#fee2e2" "$C_VPN"
    text $((x + $W / 2)) $((y + 430)) 12 700 middle "$C_TEXT" "Cluster EIP $(getv CEIP "$s")   (IPsec endpoint, follows the master)"

    # TGW and spokes below
    rect $x $((y + 470)) $W 56 "$C_TGW" "$C_TGWLINE"
    text $((x + $W / 2)) $((y + 493)) 13 700 middle "$C_TEXT" "$label Transit Gateway"
    text $((x + $W / 2)) $((y + 511)) 10.5 400 middle "$C_MUTED" "$(getv TGW "$s")   (Connect: GRE + eBGP per spoke to the primary port2; inspection attachment is transport only)"

    local k col_x cidr vpc ip
    for k in east west; do
        if [[ $k == east ]]; then col_x=$x; cidr=$(getv EAST "$s"); vpc=$(getv VPC_E "$s"); ip=$(getv SP_E "$s"); else col_x=$((x + 330)); cidr=$(getv WEST "$s"); vpc=$(getv VPC_W "$s"); ip=$(getv SP_W "$s"); fi
        rect $col_x $((y + 556)) 310 110 "$C_VPC" "#16a34a"
        text $((col_x + 10)) $((y + 576)) 13 700 start "$C_TEXT" "$label $k spoke VPC"
        text $((col_x + 10)) $((y + 593)) 10.5 400 start "$C_MUTED" "$cidr   $vpc"
        text $((col_x + 10)) $((y + 613)) 10.5 400 start "$C_TEXT" "$(subnet "$cidr" 0 26)  AZ1 workload   $(subnet "$cidr" 2 26)  AZ1 tgw"
        text $((col_x + 10)) $((y + 628)) 10.5 400 start "$C_TEXT" "$(subnet "$cidr" 1 26)  AZ2 workload   $(subnet "$cidr" 3 26)  AZ2 tgw"
        if [[ "$SPOKES_ENABLED" == "true" ]]; then
            text $((col_x + 10)) $((y + 650)) 10.5 700 start "$C_TEXT" "test instance  $ip"
        fi
        line $((col_x + 155)) $((y + 556)) $((x + $W / 2)) $((y + 526)) "$C_TGWLINE" 2
    done
    # TGW Connect (GRE + eBGP) to the primary FortiGate port2 only
    line $((x + 6)) $((y + 498)) $((x + 6)) $((y + 129)) "$C_TGWLINE" 2 "6,4"
    line $((x + 6)) $((y + 129)) $((x + 24)) $((y + 129)) "$C_TGWLINE" 2 "6,4"
    line $((x + 6)) $((y + 498)) $x $((y + 498)) "$C_TGWLINE" 2 "6,4"
}

#=============================================================================
# Build the diagram
#=============================================================================
W=2000; H=820
add "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 $W $H\" width=\"$W\" height=\"$H\" font-family=\"-apple-system, Segoe UI, Helvetica, Arial, sans-serif\">"
add "<rect width=\"$W\" height=\"$H\" fill=\"#ffffff\"/>"
text 20 28 20 700 start "$C_TEXT" "Two FortiGate FGCP HA pairs joined by IPsec"
text 20 48 12 400 start "$C_MUTED" "$PREFIX, $REGION ($AZ1, $AZ2), FortiGate $FGT_TYPE ($LICENSE), generated $TIMESTAMP"

draw_site a 20 "Site A"
draw_site b 1340 "Site B"

# Management VPC in the middle
MX=690; MW=620; MY=70
rect $MX $MY $MW 666 "$C_MGMT" "$C_MGMTLINE"
text $((MX + 12)) $((MY + 22)) 14 700 start "$C_TEXT" "Management VPC  $MGMT_CIDR  ($MGMT_VPC)"
text $((MX + 12)) $((MY + 40)) 10.5 400 start "$C_MUTED" "own IGW, not attached to either TGW. Holds every FortiGate port4 (multi-VPC ENI, no EIP: FortiManager and FortiAnalyzer only)"
for az in 0 1; do
    az_x=$((MX + 14 + az * 300)); az_name=$AZ1; [[ $az -eq 1 ]] && az_name=$AZ2
    rect $az_x $((MY + 56)) 290 230 "$C_SUB" "$C_BORDER" "5,4"
    text $((az_x + 10)) $((MY + 74)) 12 700 start "$C_MUTED" "$az_name  $(subnet "$MGMT_CIDR" "$az" 26)"
done

# FMG / FAZ (AZ1)
if [[ "$FMG_ENABLED" == "true" ]]; then
    rect $((MX + 24)) $((MY + 84)) 270 46 "#f3e8ff" "#7e22ce"
    text $((MX + 159)) $((MY + 104)) 12 700 middle "$C_TEXT" "FortiManager  $FMG_IP"
    text $((MX + 159)) $((MY + 120)) 10 400 middle "$C_MUTED" "public $FMG_EIP"
fi
if [[ "$FAZ_ENABLED" == "true" ]]; then
    rect $((MX + 24)) $((MY + 138)) 270 46 "#f3e8ff" "#7e22ce"
    text $((MX + 159)) $((MY + 158)) 12 700 middle "$C_TEXT" "FortiAnalyzer  $FAZ_IP"
    text $((MX + 159)) $((MY + 174)) 10 400 middle "$C_MUTED" "public $FAZ_EIP"
fi

# port4 ENIs: primaries in the AZ1 subnet (below FMG/FAZ), secondaries in the AZ2 subnet
for s in a b; do
    [[ $s == a ]] && lbl="Site A" || lbl="Site B"
    idx=0; [[ $s == b ]] && idx=1
    for az in 0 1; do
        if [[ $az -eq 0 ]]; then role=primary; ip=$(getv P_MG "$s"); eip=$(getv P_EIP "$s"); else role=secondary; ip=$(getv S_MG "$s"); eip=$(getv S_EIP "$s"); fi
        ex=$((MX + 24 + az * 300)); ey=$((MY + 192 + idx * 46))
        [[ $az -eq 1 ]] && ey=$((MY + 84 + idx * 46))
        rect $ex $ey 270 40 "#dbeafe" "#1d4ed8"
        text $((ex + 135)) $((ey + 17)) 11 700 middle "$C_TEXT" "$lbl $role FortiGate port4  $ip"
        text $((ex + 135)) $((ey + 32)) 10 400 middle "$C_MUTED" "no EIP"
    done
done

# Management links: from each inspection VPC edge to the management VPC edge
line 660 $((MY + 120)) $MX $((MY + 120)) "$C_MGMTLINE" 2 "4,3"
line $((MX + MW)) $((MY + 120)) 1340 $((MY + 120)) "$C_MGMTLINE" 2 "4,3"
text 675 $((MY + 112)) 10 700 middle "$C_MGMTLINE" "port4"
text 1325 $((MY + 112)) 10 700 middle "$C_MGMTLINE" "port4"

# Inter-site IPsec
text $((MX + MW / 2)) $((MY + 330)) 13 700 middle "$C_VPN" "IPsec  (IKEv2, route-based, static routes)"
text $((MX + MW / 2)) $((MY + 348)) 11 400 middle "$C_MUTED" "cluster EIP to cluster EIP; inter-site traffic only over the tunnel"
text $((MX + MW / 2)) $((MY + 412)) 11 700 middle "$C_VPN" "$(getv CEIP a)   &lt;==&gt;   $(getv CEIP b)"
line 660 $((MY + 425)) 1340 $((MY + 425)) "$C_VPN" 3 "8,5"
text $((MX + MW / 2)) $((MY + 600)) 11 400 middle "$C_MUTED" "purple dashed: port4 to the management VPC (FortiManager FGFM, FortiAnalyzer logs; VRF 1)"
text $((MX + MW / 2)) $((MY + 616)) 11 400 middle "$C_MUTED" "amber: spoke attachments    amber dashed: TGW Connect (GRE + eBGP) to primary port2    red dashed: IPsec"
add "</svg>"

printf '%s' "$SVG" >"$SVG_FILE"

#=============================================================================
# Markdown
#=============================================================================
{
    echo "# Network diagram"
    echo
    echo "Generated $TIMESTAMP from terraform state ($PREFIX, $REGION)."
    echo
    echo '![Network diagram](network_diagram.svg)'
    echo
    echo "FortiGate image: \`$FGT_AMI\`"
    echo
    echo "## VPCs"
    echo
    echo "| VPC | CIDR | VPC ID |"
    echo "|---|---|---|"
    echo "| Management | $MGMT_CIDR | $MGMT_VPC |"
    for s in a b; do
        S=$(echo "$s" | tr a-z A-Z)
        echo "| Site $S inspection | $(getv INSP "$s") | $(getv VPC_INSP "$s") |"
        echo "| Site $S east spoke | $(getv EAST "$s") | $(getv VPC_E "$s") |"
        echo "| Site $S west spoke | $(getv WEST "$s") | $(getv VPC_W "$s") |"
    done
    echo
    echo "## Inspection VPC subnets (/24)"
    echo
    echo "| Subnet | Site A AZ1 ($AZ1) | Site A AZ2 ($AZ2) | Site B AZ1 ($AZ1) | Site B AZ2 ($AZ2) |"
    echo "|---|---|---|---|---|"
    i=0
    for name in public private ha-sync tgw; do
        echo "| $name | $(subnet "$(getv INSP a)" $((i * 2)) 24) | $(subnet "$(getv INSP a)" $((i * 2 + 1)) 24) | $(subnet "$(getv INSP b)" $((i * 2)) 24) | $(subnet "$(getv INSP b)" $((i * 2 + 1)) 24) |"
        i=$((i + 1))
    done
    echo
    echo "## FortiGates"
    echo
    echo "| Site | Role | Instance | port1 (public) | port3 (HA-mgmt) | port3 EIP | port4 (mgmt VPC, no EIP) |"
    echo "|---|---|---|---|---|---|---|"
    for s in a b; do
        S=$(echo "$s" | tr a-z A-Z)
        echo "| $S | Primary | $(getv P_ID "$s") | $(getv P_P1 "$s") | $(getv P_P3 "$s") | $(getv P_EIP "$s") | $(getv P_MG "$s") |"
        echo "| $S | Secondary | $(getv S_ID "$s") | $(getv S_P1 "$s") | $(getv S_P3 "$s") | $(getv S_EIP "$s") | $(getv S_MG "$s") |"
    done
    echo
    echo "## IPsec"
    echo
    echo "| Site | Cluster EIP (tunnel endpoint) |"
    echo "|---|---|"
    echo "| A | $(getv CEIP a) |"
    echo "| B | $(getv CEIP b) |"
    echo
    echo "## Management VPC"
    echo
    echo "| Item | Private IP | Public IP |"
    echo "|---|---|---|"
    [[ "$FMG_ENABLED" == "true" ]] && echo "| FortiManager | $FMG_IP | $FMG_EIP |"
    [[ "$FAZ_ENABLED" == "true" ]] && echo "| FortiAnalyzer | $FAZ_IP | $FAZ_EIP |"
    echo
    echo "## TGW Connect (GRE and eBGP)"
    echo
    echo "Each spoke has a Connect attachment and one Connect peer to the primary FortiGate port2. GRE does not move on HA failover."
    echo
    echo "| Spoke | FortiGate GRE interface | BGP inside CIDR | FortiGate / TGW BGP peers |"
    echo "|---|---|---|---|"
    echo "| east | gre-east | 169.254.6.0/29 | .1 / .2, .3 |"
    echo "| west | gre-west | 169.254.7.0/29 | .1 / .2, .3 |"
    echo
    echo "The FortiGate (AS 65001) advertises a default route and the remote-site prefixes to the TGW (AS 64512) and learns the local spoke prefixes."
    echo
    echo "## Transit gateways and spoke test instances"
    echo
    echo "| Site | TGW | East test instance | West test instance |"
    echo "|---|---|---|---|"
    echo "| A | $(getv TGW a) | $(getv SP_E a) | $(getv SP_W a) |"
    echo "| B | $(getv TGW b) | $(getv SP_E b) | $(getv SP_W b) |"
} >"$MD_FILE"

echo "Wrote $SVG_FILE"
echo "Wrote $MD_FILE"
