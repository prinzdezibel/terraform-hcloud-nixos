#cloud-config

write_files:

${cloudinit_write_files_common}

# Add ssh authorized keys
ssh_authorized_keys:
%{ for key in sshAuthorizedKeys ~}
  - ${key}
%{ endfor ~}

%{if hcloud_server_os == "NixOS"~}
# Resize / to max available space on disk
growpart:
    devices: ["/"]
%{endif~}

%{if hcloud_server_os == "MicroOS"~}
# Resize /var, not /, as that's the last partition in MicroOS image.
growpart:
    devices: ["/var"]

# Make sure the hostname is set correctly
hostname: ${hostname}
preserve_hostname: true
%{endif~}

runcmd:

${cloudinit_runcmd_common}

%{if hcloud_server_os == "MicroOS" && swap_size != ""~}
- |
  btrfs subvolume create /var/lib/swap
  chmod 700 /var/lib/swap
  truncate -s 0 /var/lib/swap/swapfile
  chattr +C /var/lib/swap/swapfile
  fallocate -l ${swap_size} /var/lib/swap/swapfile
  chmod 600 /var/lib/swap/swapfile
  mkswap /var/lib/swap/swapfile
  swapon /var/lib/swap/swapfile
  echo "/var/lib/swap/swapfile none swap defaults 0 0" | sudo tee -a /etc/fstab
  cat << EOF >> /etc/systemd/system/swapon-late.service
  [Unit]
  Description=Activate all swap devices later
  After=default.target

  [Service]
  Type=oneshot
  ExecStart=/sbin/swapon -a

  [Install]
  WantedBy=default.target
  EOF
  systemctl daemon-reload
  systemctl enable swapon-late.service
%{endif~}
