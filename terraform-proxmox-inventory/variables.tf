variable "proxmox_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://hypervisor-1.example.com:8006/"
}

variable "proxmox_api_token" {
  type        = string
  sensitive   = true
  description = "API token in the form user@realm!tokenid=uuid"
}

variable "proxmox_insecure" {
  type        = bool
  default     = false
  description = "Skip TLS verification — only for a lab with a self-signed cert"
}

variable "template_vm_id" {
  type        = number
  description = "VM id of the cloud-init template to clone"
}

variable "ssh_public_key" {
  type        = string
  description = "Public key injected via cloud-init"
}

variable "default_user" {
  type    = string
  default = "ubuntu"
}

variable "network_gateway" {
  type = string
}

variable "network_cidr_bits" {
  type    = number
  default = 24
}

variable "inventory_path" {
  type        = string
  default     = "../ansible/inventory/hosts.yml"
  description = "Where to write the generated Ansible inventory"
}

# One map describes the whole fleet. Everything else — VMs, inventory, groups —
# is derived from it, so a machine cannot exist in Terraform but be missing
# from Ansible, which is the failure this pattern is built to prevent.
variable "nodes" {
  description = "Fleet definition, keyed by hostname"
  type = map(object({
    hypervisor  = string
    address     = string
    cores       = number
    memory      = number
    disk_gb     = number
    groups      = list(string)
    zone        = optional(string)
    user        = optional(string)
    tags        = optional(list(string), [])
    start_on_boot = optional(bool, true)
  }))

  validation {
    condition     = alltrue([for n in var.nodes : length(n.groups) > 0])
    error_message = "Every node must belong to at least one Ansible group; a host nobody manages is how drift starts."
  }

  validation {
    condition     = length(distinct([for n in var.nodes : n.address])) == length(var.nodes)
    error_message = "Two nodes share an address."
  }
}
