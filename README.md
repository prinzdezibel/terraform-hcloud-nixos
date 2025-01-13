<!-- PROJECT LOGO -->
<br />
<p align="center">
  <a href="https://github.com/mysticaltech/kube-hetzner">
    <img src="https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/raw/master/.images/kube-hetzner-logo.png" alt="Logo" width="112" height="112">
  </a>

  <h2 align="center">Kube-Hetzner</h2>
</p>

## About terraform-hcloud-nixos

Get most you know and love about the excellent [terraform-hcloud-kube-hetzner](https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner) plus a new optional configuration to use **NixOS** as operating system for the k3s cluster instead of openSUSE's MicroOS.

## Why another operating system choice?
Both OS give you the possibility to rollback to a known good state in case of a failure. But they take a different approach. While MicroOS offers a read-only, immutable root filesystem where updates are applied atomically, NixOS is not strictly read-only, but offers very good build reproducibility and rollback capabilities its through declarative system configurations known as generations.

If you find an immutable system too restricted but you still want rollback functionality, you may find NixOS a perfect alternative. Additionally, NixOS provides unparalleled reproducibility. If a system configuration runs on your machine, there's a very good chance it will on any other.

## Limitations

There are a currently a few limitations with NixOS, namely:

- Autoscaling is not yet possible
- Automatic updates of the OS is not implemented yet
- Automatic updates of the k3s cluster is not implemented yet
- Filesystem is ext4, not btrfs
- No swap for now



### 💡 Creating your kube.tf file and snapshots creation

1. Create a project in your [Hetzner Cloud Console](https://console.hetzner.cloud/), and go to **Security > API Tokens** of that project to grab the API key, it needs to be Read & Write. Take note of the key! ✅
2. Generate a passphrase-less ed25519 SSH key pair for your cluster; take note of the respective paths of your private and public keys. Or, see our detailed [SSH options](https://github.com/prinzdezibel/terraform-hcloud-nixos/blob/master/docs/ssh.md). ✅
3. Now navigate to where you want to have your project live and execute the following command, which will help you get started with a **new folder** along with the required files, and will propose you to create the mandatory snapshots. ✅

   ```sh
   tmp_script=$(mktemp) && curl -sSL -o "${tmp_script}" https://raw.githubusercontent.com/prinzdezibel/terraform-hcloud-nixos/master/scripts/create.sh && chmod +x "${tmp_script}" && "${tmp_script}" && rm "${tmp_script}"
   ```

   Or for fish shell:

   ```fish
   set tmp_script (mktemp); curl -sSL -o "{tmp_script}" https://raw.githubusercontent.com/prinzdezibel/terraform-hcloud-nixos/master/scripts/create.sh; chmod +x "{tmp_script}"; bash "{tmp_script}"; rm "{tmp_script}"
   ```

   _Optionally, for future usage, save that command as an alias in your shell preferences, like so:_

   ```sh
   alias createkh='tmp_script=$(mktemp) && curl -sSL -o "${tmp_script}" https://raw.githubusercontent.com/prinzdezibel/terraform-hcloud-nixos/master/scripts/create.sh && chmod +x "${tmp_script}" && "${tmp_script}" && rm "${tmp_script}"'
   ```

   Or for fish shell:

   ```fish
   alias createkh='set tmp_script (mktemp); curl -sSL -o "{tmp_script}" https://raw.githubusercontent.com/prinzdezibel/terraform-hcloud-nixos/master/scripts/create.sh; chmod +x "{tmp_script}"; bash "{tmp_script}"; rm "{tmp_script}"'
   ```

   

4. In that new project folder that gets created, you will find your `kube.tf` and it must be customized to suit your needs. ✅

   _A complete reference of all inputs, outputs, modules etc. can be found in the [terraform.md](https://github.com/prinzdezibel/terraform-hcloud-nixos/blob/master/docs/terraform.md) file._

### 🎯 Installation

Now that you have your `kube.tf` file, along with the OS snapshot in Hetzner project, you can start the installation process:

```sh
cd <your-project-folder>
terraform init --upgrade
terraform validate
terraform apply -auto-approve
```


_Once you start with Terraform, it's best not to change the state of the project manually via the Hetzner UI; otherwise, you may get an error when you try to run terraform again for that cluster (when trying to change the number of nodes for instance). If you want to inspect your Hetzner project, learn to use the hcloud cli._

## Usage

When your brand-new cluster is up and running, the sky is your limit! 🎉

You can view all kinds of details about the cluster by running `terraform output kubeconfig` or `terraform output -json kubeconfig | jq`.

To manage your cluster with `kubectl`, you can either use SSH to connect to a control plane node or connect to the Kube API directly.

