data "sops_file" "secrets" {
  source_file = "secrets.enc.yaml"
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = data.sops_file.secrets.data["proxmox_api_token"]
  insecure  = var.proxmox_insecure

  # talos boot is slow on first apply; raise the SSH timeout in case the
  # provider needs to fall back to SSH (it doesn't for our resources but
  # this is cheap insurance).
  ssh {
    agent = false
  }
}

provider "talos" {
  # No config here — the provider gets per-call client_configuration from
  # talos_machine_secrets, so we can manage multiple clusters from one
  # workspace if we ever need to.
}

provider "sops" {}
