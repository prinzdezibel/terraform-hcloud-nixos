/*
 * Creates a MicroOS snapshot for Kube-Hetzner
 */
packer {
  required_plugins {
    hcloud = {
      version = ">= 1.1.1"
      source  = "github.com/hetznercloud/hcloud"
    }
  }
}

variable "hcloud_token_nixos" {
  type      = string
  default   = env("HCLOUD_TOKEN")
  sensitive = true
}

# We download the OpenSUSE MicroOS x86 image from an automatically selected mirror.
variable "nixos_x86_mirror_link" {
  type    = string
  #default = "http://5.75.245.244:8080/nixos-x86_64-linux.qcow2"
  default = "https://github.com/prinzdezibel/nixos-qemu-image/releases/download/v0.9.8/nixos-x86_64-linux.qcow2"
}

# We download the OpenSUSE MicroOS ARM image from an automatically selected mirror.
variable "nixos_arm_mirror_link" {
  type    = string
  default = "https://github.com/prinzdezibel/nixos-qemu-image/releases/download/v0.9.8/nixos-aarch64-linux.qcow2"
}

# If you need to add other packages to the OS, do it here in the default value, like ["vim", "curl", "wget"]
variable "nix_packages_to_install" {
  type    = list(string)
  default = [ "neovim" ]
}

locals {
  
  # Add local variables for inline shell commands
  download_nixos_image = "wget --timeout=30 --waitretry=5 --tries=5 --retry-connrefused --inet4-only "

  write_nixos_image = <<-EOT
    set -e

    echo 'NixOS image loaded, writing to disk... '
    qemu-img convert -p -f qcow2 -O host_device $(ls -a | grep -ie '^.*qcow2$') /dev/sda

    udevadm settle --timeout=5 --exit-if-exists=/dev/sda1
    udevadm settle --timeout=5 --exit-if-exists=/dev/sda2
   
    echo 'Rebooting...'
    reboot
  EOT

  rebuild_nixos = <<-EOT
    set -euo pipefail

    echo 'Add channel...' 
    nix-channel --add https://nixos.org/channels/nixos-unstable nixos

    cd /etc/nixos

    # backup old configuration
    mv configuration.nix configuration.nix.bak

    echo "Build new configuration..."
    echo $'
    {
      pkgs,
      ...
    }:
    {
      environment.systemPackages = with pkgs; [ k3s openiscsi ] ++ [ ${join(" ", var.nix_packages_to_install)} ];
    }' > modules/system-packages.nix

    # Wipe old kernels
    rm -rf /boot/kernels
  
    nixos-generate-config

    sed -i "s/.\/hardware-configuration.nix/.\/hardware-configuration.nix\n     .\/modules/" configuration.nix
    sed -zi 's/# Use the systemd-boot EFI boot loader\.\n[^\n]*\n[^\n]*\n//' configuration.nix    
    sed -zi 's/fileSystems."\/boot" =.*{.*}.*;/fileSystems."\/boot" = { device = "\/dev\/sda1"; fsType = "vfat"; options = [ "fmask=0022" "dmask=0022" ]; };/' hardware-configuration.nix

    #echo "Change current UEFI-enabled systemd-boot to GRUB BIOS/GPT setup."
    #
    ## Have kernel images living in EFI partition is problematic, because we don't want to have it bigger than 256MB 
    #sed -i 's/boot.loader.efi.canTouchEfiVariables = true;/boot.loader.efi.canTouchEfiVariables = false;/' configuration.nix
    #sed -i 's/boot.loader.systemd-boot.enable = true;/boot.loader.grub = { enable = true; configurationLimit = 1; device = "\/dev\/sda"; efiSupport = true; efiInstallAsRemovable = true; };\nboot.loader.systemd-boot.enable = false;\nsystemd.automounts = [{ where = "\/efi"; enable = false; } { where = "\/boot"; enable = false; }];/' configuration.nix

    # Kernel images should live in main partition (works only for GRUB)
    #echo "Unmount /boot ESP"
    #systemctl stop boot.automount
    #systemctl stop boot.mount
    #mkdir -p /boot/efi
    #mount /dev/sda1 /boot/efi
    #sed -i 's/boot.loader.systemd-boot.enable = true;/boot.loader.grub = { device = "nodev"; enable = true; efiSupport = true; };\nboot.loader.efi.efiSysMountPoint = "\/boot\/efi";\nboot.loader.systemd-boot.enable = false;\nsystemd.automounts = [{ where = "\/efi"; enable = false; } { where = "\/boot"; enable = false; }];/' configuration.nix
    #sed -zi 's/fileSystems."\/boot" =.*{.*}.*;/fileSystems."\/boot\/efi" = { device = "\/dev\/sda1"; fsType = "vfat"; options = [ "fmask=0022" "dmask=0022" ]; };/' hardware-configuration.nix

    echo "Rebuild NixOS..."
    nixos-rebuild boot -I nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos/nixpkgs -I nixos-config=/etc/nixos/configuration.nix --upgrade

    echo "Cleaning-up..."   

    # clean /tmp
    rm -rf /tmp/*

    # clean logs
    journalctl --flush
    journalctl --rotate --vacuum-time=0
    find /var/log -type f -exec truncate --size 0 {} \; # truncate system logs
    find /var/log -type f -name '*.[1-9]' -delete # remove archived logs
    find /var/log -type f -name '*.gz' -delete # remove compressed archived logs


    # Reset host ssh keys
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
    
    #rm /root/.ssh/authorized_keys

    rm -rf /root/.cache/nix
  
    # Clean and reset cloud-init files 
    cloud-init clean --logs --machine-id --seed --configs all
    rm -rf /run/cloud-init/*
    rm -rf /var/lib/cloud/*

    nix-store --gc
    nix-store --optimise

    # Discard unused blocks from disk
    dd if=/dev/zero of=/zero bs=4M || true
    sync
    rm -f /zero

    # Make snapshot size match the actual file system disk usage
    fstrim -av

    echo "Done."
    sleep 1 && udevadm settle

EOT

}

# Source for the MicroOS x86 snapshot
source "hcloud" "nixos-x86-snapshot" {
  image       = "ubuntu-24.04"
  rescue      = "linux64"
  #location    = "nbg1"
  location     = "hel1"
  server_type = "cx22" # Intel Shared vCPU
  #server_type = "cpx11" # AMD Shared vCPU
  #upgrade_server_type = "cx52" # 16 cores for faster builds
  snapshot_labels = {
    nixos-snapshot = "yes"
    creator        = "kube-hetzner"
  }
  snapshot_name = "NixOS x86 by Kube-Hetzner"
  ssh_username  = "root"
  token         = var.hcloud_token_nixos
}

# Source for the MicroOS ARM snapshot
source "hcloud" "nixos-arm-snapshot" {
  image       = "ubuntu-24.04"
  rescue      = "linux64"
  #location    = "fsn1"
  location    = "hel1"
  server_type = "cax11"
  #upgrade_server_type = "cax51" # 16 cores for faster builds
  snapshot_labels = {
    nixos-snapshot = "yes"
    creator        = "kube-hetzner"
  }
  snapshot_name = "NixOS ARM by Kube-Hetzner"
  ssh_username  = "root"
  token         = var.hcloud_token_nixos
}

# Build the NixOS x86 snapshot
build {
  sources = ["source.hcloud.nixos-x86-snapshot"]

  # Download the NixOS x86 image
  provisioner "shell" {
    inline = ["${local.download_nixos_image}${var.nixos_x86_mirror_link}"]
    timeout = "30m"
  }
  
  # Write the NixOS x86 image to disk
  provisioner "shell" {
    inline            = [local.write_nixos_image]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before      = "5s"
    inline            = [local.rebuild_nixos]
  }
}


# Build the NixOS ARM snapshot
build {
  sources = ["source.hcloud.nixos-arm-snapshot"]

  # Download the MicroOS ARM image
  provisioner "shell" {
    inline = ["${local.download_nixos_image}${var.nixos_arm_mirror_link}"]
    timeout = "30m"
  }

  provisioner "shell" {
    inline            = [local.write_nixos_image]
    expect_disconnect = true
  }

  provisioner "shell" {
    pause_before      = "5s"
    inline            = [local.rebuild_nixos]
  }
}
