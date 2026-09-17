terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.95"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # State holds VM addresses and the provider's API token. Keep it remote and
  # encrypted; the commented block below is the shape, not a recommendation of
  # any particular backend.
  #
  # backend "s3" {
  #   bucket  = "tfstate"
  #   key     = "proxmox/terraform.tfstate"
  #   encrypt = true
  # }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
}
