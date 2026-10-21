config firewall address
%{ for name, cidr in admin_sources ~}
edit ${name}
set subnet ${cidr}
next
%{ endfor ~}
end

config firewall service custom
%{ for f in ssh_forwards ~}
edit ${f.name}-ssh
set tcp-portrange ${f.port}
next
%{ endfor ~}
end

config firewall vip
%{ for f in ssh_forwards ~}
edit vip-ssh-${site_label}-${f.name}
set service ${f.name}-ssh
set mappedip ${f.target_ip}
set extintf port1
set portforward enable
set mappedport 22
next
%{ endfor ~}
end

config firewall policy
%{ for i, f in ssh_forwards ~}
edit ${10 + i}
set name ssh-to-${site_label}-${f.name}
set srcintf port1
set dstintf gre-${f.spoke}
set srcaddr %{ for name, cidr in admin_sources ~}${name} %{ endfor }
set dstaddr vip-ssh-${site_label}-${f.name}
set action accept
set schedule always
set service SSH
set nat disable
set skip-vrf-match enable
set logtraffic all
next
%{ endfor ~}
end
