terraform {
  # Remote state on Garage running on TrueNAS, fronted by a Tailscale sidecar
  # (see truenas/docker-compose/garage/). Replaces MinIO after the latter was
  # archived upstream — see that README for the trade-off discussion.
  #
  # Bootstrap order: bring Garage up first, then `tofu init` here. If Garage
  # is unreachable the init will fail with a clear error.
  #
  # `use_lockfile = false`: Garage does not implement S3 conditional writes
  # (PutObject + If-None-Match), which is what OpenTofu's S3-native locking
  # relies on. Setting `use_lockfile = true` against Garage would *appear*
  # to succeed (Garage accepts the PutObject) but two concurrent applies
  # would each get a "lock" — silent corruption. Disabling locking is the
  # safe choice for a single-operator homelab; just don't run two `tofu
  # apply` in parallel.
  backend "s3" {
    bucket = "tofu-state"
    key    = "homelab/talos.tfstate"

    endpoints = {
      s3 = "https://garage.fairy-featherback.ts.net"
    }

    # Must match `s3_region` in garage.toml. Garage validates this on
    # signature check (unlike MinIO which ignored it).
    region = "garage"

    use_path_style              = true
    use_lockfile                = false # see comment above
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}
