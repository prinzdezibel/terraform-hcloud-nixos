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
  default = "http://77.7.27.12/nixos-x86_64-linux.qcow2.tar.gz"
}

# We download the OpenSUSE MicroOS ARM image from an automatically selected mirror.
variable "nixos_arm_mirror_link" {
  type    = string
  default = "http://77.7.27.12/nixos-aarch64-linux.qcow2.tar.gz"
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
    set -ex
    echo 'NixOS image loaded, writing to disk... '
    tar -xvzf $(ls -a | grep -ie '^.*qcow2.tar.gz$')
    qemu-img convert -p -f qcow2 -O host_device $(ls -a | grep -ie '^.*qcow2$') /dev/sda
    echo 'done. Rebooting...'
    sleep 1 && udevadm settle && reboot
  EOT

  install_grub = <<-EOT
    set -ex

    echo 'Add channel ...' 
    nix-channel --add https://nixos.org/channels/nixos-24.11 nixos
    
    cd /etc/nixos

    echo $'
    {
      pkgs,
      ...
    }:
    {
      environment.defaultPackages = with pkgs; [ k3s ] ++ [ ${join(" ", var.nix_packages_to_install)} ];
    }' > modules/default-packages.nix
    
    mv configuration.nix configuration.nix.bak
    mv modules/configuration.nix modules/configuration.nix.bak


    echo "Build new hardware configuration with fileSystem info ..."
    nixos-generate-config
    sed -i "s/.\/hardware-configuration.nix/.\/hardware-configuration.nix\n     .\/modules/" configuration.nix
    
    echo "Change current EFI-only boot config to Grub-EFI"
    
    sed -i 's/# Use the systemd-boot EFI boot loader\.//' configuration.nix
    sed -i 's/boot.loader.systemd-boot.enable = true;/boot.loader.grub = { device = "\/dev\/sda"; enable = true; efiSupport = true; };\nboot.loader.systemd-boot.enable = false;/' configuration.nix

    # For whatever reason the /boot filesystem is redundant and errors.
    # See also: https://github.com/NixOS/nixpkgs/issues/283889
    sed -zi 's/fileSystems."\/boot" =.*{.*}.*;//' hardware-configuration.nix

    echo "Rebuild NixOs ..."
    nixos-rebuild boot -I nixos-config=/etc/nixos/configuration.nix --upgrade

    echo "Cleaning-up..."    
    rm /root/.ssh/authorized_keys
    rm -rf /etc/ssh/ssh_host_*
    rm -rf /root/.cache/nix
    nix-store --gc
    nix-store --optimise

    # Make snapshot size match the actual disk usage
    fstrim -av

    echo "Done."
    sleep 1 && udevadm settle
EOT
}

# Source for the MicroOS x86 snapshot
source "hcloud" "nixos-x86-snapshot" {
  image       = "ubuntu-24.04"
  rescue      = "linux64"
  #location    = "fsn1"
  location     = "hel1"
  # We need a dedicated vCPU, because shared x86_64 vCPU's don't support UEFI boot
  server_type = "ccx13"
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
  server_type = "cax21" # 80Gb disk size is needed to install the NixOS image
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
    inline            = [local.install_grub]
  }
}


# Build the NixOS ARM snapshot
#build {
#  sources = ["source.hcloud.nixos-arm-snapshot"]
#
#  # Download the MicroOS ARM image
#  provisioner "shell" {
#    inline = ["${local.download_nixos_image}${var.nixos_arm_mirror_link}"]
#  }
#
#  provisioner "shell" {
#    inline            = [local.write_nixos_image]
#    expect_disconnect = true
#  }
#
#  provisioner "shell" {
#    pause_before      = "5s"
#    inline            = [local.install_grub]
#  }
#}
