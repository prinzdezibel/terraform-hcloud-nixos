module "control_planes" {
  source = "./modules/host"

  providers = {
    hcloud = hcloud,
  }

  for_each = local.control_plane_nodes

  name                         = "${var.use_cluster_name_in_node_name ? "${var.cluster_name}-" : ""}${each.value.nodepool_name}"
  hcloud_server_os             = var.hcloud_server_os
  snapshot_id                  = var.hcloud_server_os == "MicroOS" ? (substr(each.value.server_type, 0, 3) == "cax" ? data.hcloud_image.microos_arm_snapshot[0].id : data.hcloud_image.microos_x86_snapshot[0].id) : (substr(each.value.server_type, 0, 3) == "cax" ? data.hcloud_image.nixos_arm_snapshot[0].id : data.hcloud_image.nixos_x86_snapshot[0].id)
  base_domain                  = var.base_domain
  ssh_keys                     = length(var.ssh_hcloud_key_label) > 0 ? concat([local.hcloud_ssh_key_id], data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.id) : [local.hcloud_ssh_key_id]
  ssh_port                     = var.ssh_port
  ssh_public_key               = var.ssh_public_key
  ssh_private_key              = var.ssh_private_key
  ssh_additional_public_keys   = length(var.ssh_hcloud_key_label) > 0 ? concat(var.ssh_additional_public_keys, data.hcloud_ssh_keys.keys_by_selector[0].ssh_keys.*.public_key) : var.ssh_additional_public_keys
  firewall_ids                 = [hcloud_firewall.k3s.id]
  placement_group_id           = var.placement_group_disable ? null : (each.value.placement_group == null ? hcloud_placement_group.control_plane[each.value.placement_group_compat_idx].id : hcloud_placement_group.control_plane_named[each.value.placement_group].id)
  location                     = each.value.location
  server_type                  = each.value.server_type
  backups                      = each.value.backups
  ipv4_subnet_id               = hcloud_network_subnet.control_plane[[for i, v in var.control_plane_nodepools : i if v.name == each.value.nodepool_name][0]].id
  dns_servers                  = var.dns_servers
  k3s_registries               = var.k3s_registries
  k3s_registries_update_script = var.hcloud_server_os == "MicroOS" ? local.microos_k3s_registries_update_script : local.nixos_k3s_registries_update_script
  cloudinit_write_files_common = var.hcloud_server_os == "MicroOS" ? local.microos_cloudinit_write_files : local.nixos_cloudinit_write_files
  cloudinit_runcmd_common      = var.hcloud_server_os == "MicroOS" ? local.microos_cloudinit_runcmd : local.nixos_cloudinit_runcmd
  swap_size                    = each.value.swap_size
  zram_size                    = each.value.zram_size
  keep_disk_size               = var.keep_disk_cp

  # We leave some room so 100 eventual Hetzner LBs that can be created perfectly safely
  # It leaves the subnet with 254 x 254 - 100 = 64416 IPs to use, so probably enough.
  private_ipv4 = cidrhost(hcloud_network_subnet.control_plane[[for i, v in var.control_plane_nodepools : i if v.name == each.value.nodepool_name][0]].ip_range, each.value.index + 101)

  labels = merge(local.labels, local.labels_control_plane_node)

  automatically_upgrade_os = var.automatically_upgrade_os

  depends_on = [
    hcloud_network_subnet.control_plane,
    hcloud_placement_group.control_plane,
  ]
}

resource "hcloud_load_balancer" "control_plane" {
  count = var.use_control_plane_lb ? 1 : 0
  name  = "${var.cluster_name}-control-plane"

  load_balancer_type = var.control_plane_lb_type
  location           = var.load_balancer_location
  labels             = merge(local.labels, local.labels_control_plane_lb)
  delete_protection  = var.enable_delete_protection.load_balancer
}

resource "hcloud_load_balancer_network" "control_plane" {
  count = var.use_control_plane_lb ? 1 : 0

  load_balancer_id        = hcloud_load_balancer.control_plane.*.id[0]
  subnet_id               = hcloud_network_subnet.control_plane.*.id[0]
  enable_public_interface = var.control_plane_lb_enable_public_interface
  ip                      = cidrhost(hcloud_network_subnet.control_plane.*.ip_range[0], 1)
}

resource "hcloud_load_balancer_target" "control_plane" {
  count = var.use_control_plane_lb ? 1 : 0

  depends_on       = [hcloud_load_balancer_network.control_plane]
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.control_plane.*.id[0]
  label_selector   = join(",", [for k, v in merge(local.labels, local.labels_control_plane_node) : "${k}=${v}"])
  use_private_ip   = true
}

resource "hcloud_load_balancer_service" "control_plane" {
  count = var.use_control_plane_lb ? 1 : 0

  load_balancer_id = hcloud_load_balancer.control_plane.*.id[0]
  protocol         = "tcp"
  destination_port = "6443"
  listen_port      = "6443"
}

locals {
  k3s-config = { for k, v in local.control_plane_nodes : k => merge(
    {
      node-name = module.control_planes[k].name
      server = length(module.control_planes) == 1 ? null : "https://${
        var.use_control_plane_lb ? hcloud_load_balancer_network.control_plane.*.ip[0] :
        module.control_planes[k].private_ipv4_address == module.control_planes[keys(module.control_planes)[0]].private_ipv4_address ?
        module.control_planes[keys(module.control_planes)[1]].private_ipv4_address :
      module.control_planes[keys(module.control_planes)[0]].private_ipv4_address}:6443"
      token                       = local.k3s_token
      disable-cloud-controller    = true
      disable-kube-proxy          = var.disable_kube_proxy
      disable                     = local.disable_extras
      kubelet-arg                 = concat(local.kubelet_arg, var.k3s_global_kubelet_args, var.k3s_control_plane_kubelet_args, v.kubelet_args)
      kube-apiserver-arg          = local.kube_apiserver_arg
      kube-controller-manager-arg = local.kube_controller_manager_arg
      flannel-iface               = local.flannel_iface
      node-ip                     = module.control_planes[k].private_ipv4_address
      advertise-address           = module.control_planes[k].private_ipv4_address
      node-label                  = v.labels
      node-taint                  = v.taints
      cluster-cidr                = var.cluster_ipv4_cidr
      service-cidr                = var.service_ipv4_cidr
      cluster-dns                 = var.cluster_dns_ipv4
      write-kubeconfig-mode       = "0644" # needed for import into rancher
    },
    v.selinux == true ? { selinux = true } : {},
    lookup(local.cni_k3s_settings, var.cni_plugin, {}),
    var.use_control_plane_lb ? {
      tls-san = concat([hcloud_load_balancer.control_plane.*.ipv4[0], hcloud_load_balancer_network.control_plane.*.ip[0]], var.additional_tls_sans)
      } : {
      tls-san = concat([
        module.control_planes[k].ipv4_address
      ], var.additional_tls_sans)
    },
    local.etcd_s3_snapshots,
    var.control_planes_custom_config
  ) }
}

resource "null_resource" "control_plane_config" {
  for_each = local.control_plane_nodes

  triggers = {
    control_plane_id = module.control_planes[each.key].id
    config           = sha1(yamlencode(local.k3s-config[each.key]))
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Generating k3s server config file
  provisioner "file" {
    content     = yamlencode(local.k3s-config[each.key])
    destination = "/tmp/config.yaml"
  }

  provisioner "remote-exec" {
    inline = var.hcloud_server_os == "MicroOS" ? [local.microos_k3s_config_update_script] : [local.nixos_k3s_config_update_script]
  }

  depends_on = [
    null_resource.first_control_plane_start_server,
    hcloud_network_subnet.control_plane
  ]
}

resource "null_resource" "control_plane_configure_private_interface" {

  for_each = { for k, v in local.control_plane_nodes : k => v if(var.hcloud_server_os == "NixOS") }
  #for_each = local.control_plane_nodes

  triggers = {
    control_plane_id = module.control_planes[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit",
      "export IPV4_PRIVATE=${module.control_planes[each.key].private_ipv4_address}",
      local.configure_private_interface
    ]
  }

  depends_on = [
    hcloud_network_subnet.control_plane
  ]
}

resource "null_resource" "authentication_config" {
  for_each = {
    for k, v in local.control_plane_nodes : k => v
    if var.hcloud_server_os == "MicroOS" && var.authentication_config != ""
  }

  triggers = {
    control_plane_id      = module.control_planes[each.key].id
    authentication_config = sha1(var.authentication_config)
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "file" {
    content     = var.authentication_config
    destination = "/tmp/authentication_config.yaml"
  }

  provisioner "remote-exec" {
    inline = [local.k3s_authentication_config_update_script]
  }

  depends_on = [
    null_resource.first_control_plane_start_server,
    hcloud_network_subnet.control_plane
  ]
}

resource "null_resource" "control_planes" {
  for_each = local.control_plane_nodes

  triggers = {
    control_plane_id = module.control_planes[each.key].id
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  # Install k3s server
  provisioner "remote-exec" {
    inline = var.hcloud_server_os == "MicroOS" ? local.microos_install_k3s_server : concat([
      "export INIT_CLUSTER=false",
      "export ROLE=server",
      "export SERVER_ARGS=\"${var.k3s_exec_server_args}\"",
      ],
      local.nixos_install_k3s
    )
  }

  depends_on = [
    null_resource.first_control_plane_start_server,
    null_resource.control_plane_config,
    null_resource.authentication_config,
    hcloud_network_subnet.control_plane
  ]
}

resource "null_resource" "nixos_rebuild_control_planes" {
  for_each = {
    for k, v in local.control_plane_nodes : k => v if var.hcloud_server_os == "NixOS"
  }

  connection {
    user           = "root"
    private_key    = var.ssh_private_key
    agent_identity = local.ssh_agent_identity
    host           = module.control_planes[each.key].ipv4_address
    port           = var.ssh_port
  }

  provisioner "remote-exec" {
    inline = [
      "set -o errexit",
      "nixos-rebuild switch"
    ]
  }

  depends_on = [
    module.control_planes,
    null_resource.first_control_plane_start_server,
    null_resource.control_plane_config,
    null_resource.control_plane_configure_private_interface,
    null_resource.authentication_config,
  ]
}
