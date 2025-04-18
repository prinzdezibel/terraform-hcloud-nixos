module "agents" {
  source = "./modules/host"

  providers = {
    hcloud = hcloud,
  }

  for_each = local.agent_nodes

  name                         = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${each.value.nodepool_name}${try(each.value.node_name_suffix, "")}"
  hcloud_server_os             = var.hcloud_server_os
  snapshot_id                  = var.hcloud_server_os == "MicroOS" ? (substr(each.value.server_type, 0, 3) == "cax" ? data.hcloud_image.microos_arm_snapshot[0].id : data.hcloud_image.microos_x86_snapshot[0].id) : (substr(each.value.server_type, 0, 3) == "cax" ? data.hcloud_image.nixos_arm_snapshot[0].id : data.hcloud_image.nixos_x86_snapshot[0].id)
  base_domain                  = var.base_domain
  ssh_keys                     = length(var.ssh_hcloud_key_label) > 0 ? concat([local.hcloud_ssh_key_id], data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.id) : [local.hcloud_ssh_key_id]
  ssh_port                     = var.ssh_port
  ssh_public_key               = var.ssh_public_key
  ssh_private_key              = var.ssh_private_key
  ssh_additional_public_keys   = length(var.ssh_hcloud_key_label) > 0 ? concat(var.ssh_additional_public_keys, data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.public_key) : var.ssh_additional_public_keys
  firewall_ids                 = [hcloud_firewall.k3s.id]
  placement_group_id           = var.placement_group_disable ? null : (each.value.placement_group == null ? hcloud_placement_group.agent[each.value.placement_group_compat_idx].id : hcloud_placement_group.agent_named[each.value.placement_group].id)
  location                     = each.value.location
  server_type                  = each.value.server_type
  backups                      = each.value.backups
  ipv4_subnet_id               = hcloud_network_subnet.agent[[for i, v in var.agent_nodepools : i if v.name == each.value.nodepool_name][0]].id
  dns_servers                  = var.dns_servers
  k3s_registries               = var.k3s_registries
  k3s_registries_update_script = var.hcloud_server_os == "MicroOS" ? local.microos_k3s_registries_update_script : local.nixos_k3s_registries_update_script
  cloudinit_write_files_common = var.hcloud_server_os == "MicroOS" ? local.microos_cloudinit_write_files : local.nixos_cloudinit_write_files
  cloudinit_runcmd_common      = var.hcloud_server_os == "MicroOS" ? local.microos_cloudinit_runcmd : local.nixos_cloudinit_runcmd
  swap_size                    = each.value.swap_size
  zram_size                    = each.value.zram_size
  keep_disk_size               = var.keep_disk_agents

  private_ipv4 = cidrhost(hcloud_network_subnet.agent[[for i, v in var.agent_nodepools : i if v.name == each.value.nodepool_name][0]].ip_range, each.value.index + 101)

  labels = merge(local.labels, local.labels_agent_node)

  automatically_upgrade_os = var.automatically_upgrade_os

  depends_on = [
    hcloud_network_subnet.agent,
    hcloud_placement_group.agent
  ]
}

locals {
  k3s-agent-config = { for k, v in local.agent_nodes : k => merge(
    {
      node-name     = module.agents[k].name
      server        = "https://${var.use_control_plane_lb ? hcloud_load_balancer_network.control_plane.*.ip[0] : module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
      token         = local.k3s_token
      kubelet-arg   = concat(local.kubelet_arg, var.k3s_global_kubelet_args, var.k3s_agent_kubelet_args, v.kubelet_args)
      flannel-iface = local.flannel_iface
      node-ip       = module.agents[k].private_ipv4_address
      node-label    = v.labels
      node-taint    = v.taints
    },
    var.agent_nodes_custom_config,
    v.selinux == true ? { selinux = true } : {}
  ) }
}

resource "null_resource" "agent_config" {
  for_each = local.agent_nodes

  triggers = {
    agent_id = module.agents[each.key].id
    config   = sha1(yamlencode(local.k3s-agent-config[each.key]))
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Generating k3s agent config file
  provisioner "file" {
    content     = yamlencode(local.k3s-agent-config[each.key])
    destination = "/tmp/config.yaml"
  }

  provisioner "remote-exec" {
    inline = var.hcloud_server_os == "MicroOS" ? [local.microos_k3s_config_update_script] : [local.nixos_k3s_config_update_script]
  }
}

resource "null_resource" "agent_configure_private_interface" {

  for_each = { for k, v in local.agent_nodes : k => v if(var.hcloud_server_os == "NixOS") }
  #for_each = local.agent_nodes

  triggers = {
    agent_id = module.agents[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit",
      "export IPV4_PRIVATE=${module.agents[each.key].private_ipv4_address}",
      local.configure_private_interface
    ]
  }

  depends_on = [
    hcloud_network_subnet.agent
  ]
}

resource "null_resource" "agents" {
  for_each = local.agent_nodes

  triggers = {
    agent_id = module.agents[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Install k3s agent
  provisioner "remote-exec" {
    inline = var.hcloud_server_os == "MicroOS" ? local.microos_install_k3s_agent : local.nixos_install_k3s_agent
  }

  depends_on = [
    null_resource.first_control_plane_start_server,
    null_resource.agent_config,
    hcloud_network_subnet.agent
  ]
}

resource "hcloud_volume" "longhorn_volume" {
  for_each = { for k, v in local.agent_nodes : k => v if((v.longhorn_volume_size >= 10) && (v.longhorn_volume_size <= 10240) && var.enable_longhorn) }

  labels = {
    provisioner = "terraform"
    cluster     = var.cluster_name
    scope       = "longhorn"
  }
  name              = "${var.cluster_name}-longhorn-${module.agents[each.key].name}"
  size              = local.agent_nodes[each.key].longhorn_volume_size
  server_id         = module.agents[each.key].id
  automount         = true
  format            = var.longhorn_fstype
  delete_protection = var.enable_delete_protection.volume
}

resource "null_resource" "configure_longhorn_volume" {
  for_each = { for k, v in local.agent_nodes : k => v if((v.longhorn_volume_size >= 10) && (v.longhorn_volume_size <= 10240) && var.enable_longhorn) }

  triggers = {
    agent_id = module.agents[each.key].id
  }

  # Start the k3s agent and wait for it to have started
  provisioner "remote-exec" {
    inline = [
      "mkdir /var/longhorn >/dev/null 2>&1",
      "mount -o discard,defaults ${hcloud_volume.longhorn_volume[each.key].linux_device} /var/longhorn",
      "${var.longhorn_fstype == "ext4" ? "resize2fs" : "xfs_growfs"} ${hcloud_volume.longhorn_volume[each.key].linux_device}",
      "echo '${hcloud_volume.longhorn_volume[each.key].linux_device} /var/longhorn ${var.longhorn_fstype} discard,nofail,defaults 0 0' >> /etc/fstab"
    ]
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  depends_on = [
    hcloud_volume.longhorn_volume
  ]
}

resource "hcloud_floating_ip" "agents" {
  for_each = { for k, v in local.agent_nodes : k => v if coalesce(lookup(v, "floating_ip"), false) }

  type              = "ipv4"
  labels            = local.labels
  home_location     = each.value.location
  delete_protection = var.enable_delete_protection.floating_ip
}

resource "hcloud_floating_ip_assignment" "agents" {
  for_each = { for k, v in local.agent_nodes : k => v if coalesce(lookup(v, "floating_ip"), false) }

  floating_ip_id = hcloud_floating_ip.agents[each.key].id
  server_id      = module.agents[each.key].id

  depends_on = [
    null_resource.nixos_rebuild_agents
  ]
}

resource "hcloud_rdns" "agents" {
  for_each = { for k, v in local.agent_nodes : k => v if lookup(v, "floating_ip_rdns", null) != null }

  floating_ip_id = hcloud_floating_ip.agents[each.key].id
  ip_address     = hcloud_floating_ip.agents[each.key].ip_address
  dns_ptr        = local.agent_nodes[each.key].floating_ip_rdns

  depends_on = [
    hcloud_floating_ip.agents
  ]
}

resource "null_resource" "configure_floating_ip" {
  for_each = { for k, v in local.agent_nodes : k => v if coalesce(lookup(v, "floating_ip"), false) }

  triggers = {
    agent_id       = module.agents[each.key].id
    floating_ip_id = hcloud_floating_ip.agents[each.key].id
  }

  provisioner "remote-exec" {
    inline = [
      # Reconfigure eth0:
      #  - add floating_ip as first and other IP as second address
      #  - add 172.31.1.1 as default gateway (In the Hetzner Cloud, the
      #    special private IP address 172.31.1.1 is the default
      #    gateway for the public network)
      # The configuration is stored in file /etc/NetworkManager/system-connections/cloud-init-eth0.nmconnection
      <<-EOT
      NM_CONNECTION=$(nmcli -g GENERAL.CONNECTION device show eth0)
      nmcli connection modify "$NM_CONNECTION" \
        ipv4.method manual \
        ipv4.addresses ${hcloud_floating_ip.agents[each.key].ip_address}/32,${module.agents[each.key].ipv4_address}/32 gw4 172.31.1.1 \
        ipv4.route-metric 100 \
      && nmcli connection up "$NM_CONNECTION"
      EOT
    ]
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  depends_on = [
    hcloud_floating_ip_assignment.agents
  ]
}

resource "null_resource" "nixos_rebuild_agents" {
  for_each = {
    for k, v in local.agent_nodes : k => v if var.hcloud_server_os == "NixOS"
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit",
      "nixos-rebuild switch"
    ]
  }

  depends_on = [
    module.agents,
    null_resource.first_control_plane_start_server,
    null_resource.agent_config,
    null_resource.agent_configure_private_interface,
  ]
}


resource "null_resource" "agents_start_server" {

  for_each = local.agent_nodes

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.agents[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Start the k3s agent and wait for it to have started
  provisioner "remote-exec" {
    inline = concat(var.enable_longhorn || var.enable_iscsid ? ["systemctl enable --now iscsid"] : [], [
      var.hcloud_server_os == "MicroOS" ? "SERVICE_NAME=k3s-agent" : "SERVICE_NAME=k3s",
      "systemctl start $SERVICE_NAME 2> /dev/null",
      <<-EOT
      timeout 120 bash <<EOF
        until systemctl status $SERVICE_NAME > /dev/null; do
          systemctl start $SERVICE_NAME 2> /dev/null
          echo "Waiting for the k3s agent to start..."
          sleep 2
        done
      EOF
      EOT
    ])
  }

  depends_on = [null_resource.nixos_rebuild_agents]
}
