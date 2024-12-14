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
  #default = "http://77.2.191.221/nixos-x86_64-linux.qcow2"
  default = "https://github.com/prinzdezibel/nixos-qemu-image/releases/download/v0.9.1/nixos-x86_64-linux.qcow2"
}

# We download the OpenSUSE MicroOS ARM image from an automatically selected mirror.
variable "nixos_arm_mirror_link" {
  type    = string
  #default = "http://77.2.191.221/nixos-aarch64-linux.qcow2"
  default = "https://github.com/prinzdezibel/nixos-qemu-image/releases/download/v0.9.1/nixos-aarch64-linux.qcow2"
}

# If you need to add other packages to the OS, do it here in the default value, like ["vim", "curl", "wget"]
variable "nix_packages_to_install" {
  type    = list(string)
  default = [ "neovim" ]
}

locals {
  
  # Add local variables for inline shell commands
  download_nixos_image = "wget --timeout=5 --waitretry=5 --tries=5 --retry-connrefused --inet4-only "

  write_nixos_image = <<-EOT
    set -e

    echo 'NixOS image loaded, writing to disk... '
    qemu-img convert -p -f qcow2 -O host_device $(ls -a | grep -ie '^.*qcow2$') /dev/sda

    echo 'Rebooting...'
    sleep 1 && udevadm settle && reboot
  EOT

  rebuild_nixos = <<-EOT
    set -euo pipefail

    echo 'Add channel...' 
    nix-channel --add https://nixos.org/channels/nixos-24.11 nixos

    cd /etc/nixos

    # backup old configuration
    mv configuration.nix configuration.nix.bak
    mv modules/configuration.nix modules/configuration.nix.bak

    echo "Build new configuration..."
    echo $'
    {...}:
    {
      services.k3s.enable = true;
    }' > modules/k3s.enable.nix

    echo $'
    {
      pkgs,
      ...
    }:
    {
      environment.systemPackages = with pkgs; [ k3s ] ++ [ ${join(" ", var.nix_packages_to_install)} ];
    }' > modules/system-packages.nix

    # Wipe old kernels
    rm -rf /boot/kernels

    # Stop systemd automounted /boot to stop nixos-generate-config from generating /boot automount in hardware-configuration.nix
    echo "Unmount /boot ESP"
    systemctl stop boot.automount
    systemctl stop boot.mount
    
    nixos-generate-config
    sed -i "s/.\/hardware-configuration.nix/.\/hardware-configuration.nix\n     .\/modules/" configuration.nix
    
    echo "Change current systemd-boot to Grub-EFI"

    sed -i 's/# Use the systemd-boot EFI boot loader\.//' configuration.nix
    
    # Have kernel images living in EFI partition is problematic, because we don't want to have it bigger than 256MB 
    #sed -i 's/boot.loader.systemd-boot.enable = true;/boot.loader.grub = { configurationLimit = 1; device = "\/dev\/sda"; enable = true; efiSupport = true; };\nboot.loader.systemd-boot.enable = false;\nsystemd.automounts = [{ where = "\/boot"; enable = false; }];/' configuration.nix
    #sed -zi 's/fileSystems."\/boot" =.*{.*}.*;/fileSystems."\/boot" = { device = "\/dev\/sda1"; fsType = "vfat"; options = [ "fmask=0022" "dmask=0022" ]; };/' hardware-configuration.nix

    # Kernel images should live in main partition (works only for GRUB)
    mkdir -p /boot/efi
    mount /dev/sda1 /boot/efi
    sed -i 's/boot.loader.systemd-boot.enable = true;/boot.loader.grub = { device = "nodev"; enable = true; efiSupport = true; };\nboot.loader.efi.efiSysMountPoint = "\/boot\/efi";\nboot.loader.systemd-boot.enable = false;\nsystemd.automounts = [{ where = "\/boot"; enable = false; }];/' configuration.nix
    sed -zi 's/fileSystems."\/boot" =.*{.*}.*;/fileSystems."\/boot\/efi" = { device = "\/dev\/sda1"; fsType = "vfat"; options = [ "fmask=0022" "dmask=0022" ]; };/' hardware-configuration.nix
    

    echo "Rebuild NixOS..."
    nixos-rebuild boot -I nixos-config=/etc/nixos/configuration.nix --upgrade

    echo "Cleaning-up..."    
    rm /root/.ssh/authorized_keys
    rm -rf /etc/ssh/ssh_host_*
    rm -rf /root/.cache/nix
    nix-store --gc
    nix-store --optimise

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
  location    = "fsn1"
  #location     = "hel1"
  server_type = "ccx13"  # We need a dedicated vCPU, because shared x86_64 vCPU's don't support UEFI boot
  #server_type = "cx22" # Shared vCPU
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
  location    = "fsn1"
  server_type = "cax11"
  snapshot_labels = {
    nixos-snapshot = "yes"
    creator          = "kube-hetzner"
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
