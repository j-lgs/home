terraform {
  required_providers {
    proxmox = {
      source = "Telmate/proxmox"
      version = "2.9.14"
    }
    sops = {
      source = "carlpett/sops"
      version = "0.7.2"
    }
  }
}

provider "proxmox" {
  pm_api_url = "https://chireiden.lan:8006/api2/json"
}

data "sops_file" "terraform_secrets" {
  source_file = "terraform-secrets.enc.yaml"
}

variable "lxc_template" {
  default = "local-btrfs:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst"
}

variable "windows_iso" {
  default = "local-btrfs:iso/en-us_windows_server_2022_x64_dvd_620d7eac.iso"
}

variable "ip4_gateway" {
  default = "10.0.0.1"
}

variable "ip6_gateway" {
  default = "2404:e80:6423:1000:7e2b:e1ff:fe13:89d8"
}

variable "net_dns" {
  default = "2404:e80:6423:1000:7e2b:e1ff:fe13:89d8"
}

variable "inventory_file" {
  default = "inventory/prod"
}

locals {
  machine_ssh_keys = <<-EOT
    ${ data.sops_file.terraform_secrets.data["machine_ssh"] }
  EOT

  machine_configs = {
    yatagarasu  = { vmid = 104, pw = data.sops_file.terraform_secrets.data["password.yatagarasu"] }
    oni         = { vmid = 105, pw = data.sops_file.terraform_secrets.data["password.oni"] }
    hashihime   = { vmid = 107, pw = data.sops_file.terraform_secrets.data["password.hashihime"] }
    satori      = { vmid = 108, pw = data.sops_file.terraform_secrets.data["password.satori"] }
    tsukumogami = { vmid = 110, pw = data.sops_file.terraform_secrets.data["password.tsukumogami"] }
    tsuchigumo  = { vmid = 201 }
  }
}

data "template_file" "prod_hosts" {
  template = "${file("${path.module}/templates/prod_hosts.tpl")}"
  count    = "${length(local.machine_configs)}"
  vars = {
    hostname = "${keys(local.machine_configs)[count.index]}"
    vmid = "${values(local.machine_configs)[count.index].vmid}"
  }
}

data "template_file" "ansible_inventory" {
  template = "${file("${path.module}/templates/inventory.tpl")}"
  vars = {
    prod_hosts = "${join("", data.template_file.prod_hosts.*.rendered)}"
  }
}

resource "local_file" "inventory" {
  content  = data.template_file.ansible_inventory.rendered
  filename = var.inventory_file
}

resource "proxmox_lxc" "yatagarasu" {
  target_node = "chireiden"
  hostname    = "yatagarasu"
  ostemplate  = var.lxc_template
  password    = local.machine_configs["yatagarasu"].pw
  vmid        = local.machine_configs.yatagarasu.vmid
  
  ostype       = "debian"
  unprivileged = true

  description = <<-EOT
    Samba fileserver for the windows network. User shares will be on AD machine tsuchigumo.
  EOT

  cores  = 2
  swap   = 512
  memory = 2048

  onboot = true
  start  = true

  tags = "debian;production;samba"

  features {
    nesting = true
  }

  ssh_public_keys = local.machine_ssh_keys

  rootfs {
    storage = "chireiden-flash"
    size    = "8G"
  }

  mountpoint {
    slot = 0
    key  = "0"
    mp   = "/mnt/download/inbox"
    storage = "/rust1/download/seeding"
    volume  = "/rust1/download/seeding"
    size = "0T"
  }

  mountpoint {
    slot = 1
    key  = "1"
    mp   = "/mnt/media/anime"
    storage = "/rust1/media/anime"
    volume  = "/rust1/media/anime"
    size = "0T"
  }

  mountpoint {
    slot = 2
    key  = "2"
    mp   = "/mnt/media/movie"
    storage = "/rust1/media/movie"
    volume  = "/rust1/media/movie"
    size = "0T"
  }

  mountpoint {
    slot = 3
    key  = "3"
    mp   = "/mnt/media/tv"
    storage = "/rust1/media/tv"
    volume  = "/rust1/media/tv"
    size = "0T"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
    ip6    = "dhcp"
  }

  # Suppress changes from the buggy way Proxmox's API handles bind mounts.
  lifecycle {
    ignore_changes = [
      mountpoint[0].storage,
      mountpoint[1].storage,
      mountpoint[2].storage,
      mountpoint[3].storage
    ]
  }
}

resource "proxmox_lxc" "oni" {
  target_node = "chireiden"
  
  hostname    = "oni"
  ostemplate  = var.lxc_template
  password    = local.machine_configs.oni.pw
  vmid        = local.machine_configs.oni.vmid

  ostype       = "debian"
  unprivileged = true

  description =  <<-EOT
    Docker host for self-hosted services.
  EOT

  cores  = 8
  swap   = 1024
  memory = 8192 

  onboot = true
  start  = true

  tags = "betanin;debian;production;shokoanime"

  features {
    nesting = true
  }

  ssh_public_keys = local.machine_ssh_keys

  nameserver   = var.net_dns
  searchdomain = "lan"

  rootfs {
    storage = "chireiden-flash"
    size    = "16G"
  }

  mountpoint {
    slot = 0
    key  = "0"
    storage = "/dev/zvol/flasah1/disks/docker_lxc"
    size = "64G"
    mp  = "/var/lib/docker"
  }

  mountpoint {
    slot = 1
    key  = "1"
    mp   = "/mnt/download/inbox"
    storage = "/rust1/download/seeding"
    volume  = "/rust1/download/seeding"
    size = "0T"
  }

  mountpoint {
    slot = 2
    key  = "2"
    mp   = "/mnt/media/music"
    storage = "/rust1/media/music"
    volume  = "/rust1/media/music"
    size = "0T"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
    ip6    = "dhcp"
  }

  # Suppress changes from the buggy way Proxmox's API handles bind mounts.
  lifecycle {
    ignore_changes = [
      mountpoint[0].storage,
      mountpoint[0].size,
      mountpoint[1].storage,
      mountpoint[2].storage
    ]
  }
}

resource "proxmox_lxc" "hashihime" {
  target_node = "chireiden"
  hostname    = "hashihime"
  ostemplate  = var.lxc_template
  password    = local.machine_configs.hashihime.pw
  vmid        = local.machine_configs.hashihime.vmid
  
  ostype       = "debian"
  unprivileged = true

  description = <<-EOT
    Docker host jellyfin, will have gpu attached.
  EOT

  cores  = 8
  swap   = 1024
  memory = 8192

  onboot = true
  start  = true

  tags = "debian;jellyfin;production"

  features {
    nesting = true
	mknod = true
  }

  ssh_public_keys = local.machine_ssh_keys

  rootfs {
    storage = "chireiden-flash"
    size    = "8G"
  }

  mountpoint {
    slot = 0
    key  = "0"
    mp   = "/mnt/download/inbox"
    storage = "/rust1/download/seeding"
    volume  = "/rust1/download/seeding"
    size = "0T"
  }

  mountpoint {
    slot = 1
    key  = "1"
    mp   = "/mnt/media/anime"
    storage = "/rust1/media/anime"
    volume  = "/rust1/media/anime"
    size = "0T"
  }

  mountpoint {
    slot = 2
    key  = "2"
    mp   = "/mnt/media/movie"
    storage = "/rust1/media/movie"
    volume  = "/rust1/media/movie"
    size = "0T"
  }

  mountpoint {
    slot = 3
    key  = "3"
    mp   = "/mnt/media/tv"
    storage = "/rust1/media/tv"
    volume  = "/rust1/media/tv"
    size = "0T"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    ip     = "dhcp"
    ip6    = "dhcp"
  }

  # Suppress changes from the buggy way Proxmox's API handles bind mounts.
  lifecycle {
    ignore_changes = [
      mountpoint[0].storage,
      mountpoint[1].storage,
      mountpoint[2].storage,
      mountpoint[3].storage
    ]
  }
}

resource "proxmox_lxc" "satori" {
  target_node = "chireiden"
  hostname    = "satori"
  ostemplate  = var.lxc_template
  password    = local.machine_configs.satori.pw
  vmid        = local.machine_configs.satori.vmid
  
  ostype       = "debian"
  unprivileged = true

  nameserver   = var.net_dns
  searchdomain = "lan"

  description = <<-EOT
    Reverse proxy and wireguard connection host.
  EOT

  cores  = 1
  swap   = 512
  memory = 512

  onboot = true
  start  = true

  tags = "debian;ingress;production"

  features {
    nesting = true
  }

  ssh_public_keys = local.machine_ssh_keys

  rootfs {
    storage = "chireiden-flash"
    size    = "8G"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    gw     = var.ip4_gateway
    ip     = "10.0.0.20/24"
    gw6    = var.ip6_gateway
    ip6    = "2404:e80:6423:1000::1000:601/64"
  }
}

resource "proxmox_lxc" "tsukumogami" {
  target_node = "chireiden"
  hostname    = "tsukumogami"
  ostemplate  = var.lxc_template
  password    = local.machine_configs.tsukumogami.pw
  vmid        = local.machine_configs.tsukumogami.vmid
  
  ostype       = "debian"
  unprivileged = false

  nameserver   = var.net_dns
  searchdomain = "lan"

  description = <<-EOT
    Roon and navidrome host.
  EOT

  cores  = 4
  swap   = 512
  memory = 4096

  onboot = true
  start  = true

  tags = "debian;navidrome;production;roon"

  features {
    nesting = true
	  mknod   = true
    mount   = "cifs"
  }

  ssh_public_keys = local.machine_ssh_keys

  rootfs {
    storage = "chireiden-flash"
    size    = "64G"
  }

  mountpoint {
    slot = 0
    key  = "0"
    mp   = "/mnt/media/music"
    storage = "/rust1/media/music"
    volume  = "/rust1/media/music"
    size = "0T"
  }

  mountpoint {
    slot = 1
    key  = "1"
    mp   = "/mnt/download/inbox"
    storage = "/rust1/download/seeding"
    volume  = "/rust1/download/seeding"
    size = "0T"
  }

  network {
    name   = "eth0"
    bridge = "vmbr0"
    gw     = var.ip4_gateway
    ip     = "10.0.0.25/24"
    gw6    = var.ip6_gateway
    ip6    = "2404:e80:6423:1000::1000:600/64"
  }

  # Suppress changes from the buggy way Proxmox's API handles bind mounts.
  lifecycle {
    ignore_changes = [
      mountpoint[0].storage,
      mountpoint[1].storage
    ]
  }
}

resource "proxmox_vm_qemu" "tsuchigumo" {
  name        = "tsuchigumo"
  target_node = "chireiden"
  iso         = var.windows_iso
  vmid        = local.machine_configs.tsuchigumo.vmid

  desc = "Windows server and active directory lab."

  bios = "ovmf"

  hastate = "stopped"

  onboot = true

  os_type = "win11"

  scsihw = "virtio-scsi-single"

  cores = 4
  memory = 12288

  tags = "windows;AD;production"
  
  disk {
    type = "scsi"
    storage = "chireiden-flash"
    size =  "100G"
    iothread = 1
    ssd = 1
    discard = "on"
    backup  = true
  }
  
  network {
    model = "virtio"
    bridge = "vmbr0"
    firewall = true
  }

  lifecycle {
    ignore_changes = [
      network, disk, sshkeys, target_node, hastate, qemu_os
    ]
  }
}
