terraform {
  # OpenTofu 1.9+ for `use_lockfile` (S3-native locking) on the s3 backend.
  required_version = ">= 1.9"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.107"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
