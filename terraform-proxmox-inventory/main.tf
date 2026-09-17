# VMs cloned from a cloud-init template, one per entry in var.nodes.
resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name      = each.key
  node_name = each.value.hypervisor
  tags      = concat(each.value.tags, each.value.zone != null ? ["zone-${each.value.zone}"] : [])

  on_boot = each.value.start_on_boot

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"   # pass through the host CPU; migration across identical
                     # hardware still works and the guest gets real flags
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  initialization {
    ip_config {
      ipv4 {
        address = "${each.value.address}/${var.network_cidr_bits}"
        gateway = var.network_gateway
      }
    }

    user_account {
      username = coalesce(each.value.user, var.default_user)
      keys     = [var.ssh_public_key]
    }
  }

  network_device {
    bridge = "vmbr0"
  }

  lifecycle {
    # The guest OS owns its own disk after first boot. Without this, a change
    # to the template turns `terraform apply` into a fleet rebuild.
    ignore_changes = [disk, initialization]
  }
}

# The inventory is generated from the same map that created the VMs, so the
# two cannot disagree. This is the whole point of the pattern: provisioning
# and configuration read one source of truth instead of two that drift.
locals {
  all_groups = distinct(flatten([for n in var.nodes : n.groups]))

  inventory = {
    for group in local.all_groups : group => {
      hosts = {
        for name, n in var.nodes : name => merge(
          {
            ansible_host = n.address
            ansible_user = coalesce(n.user, var.default_user)
          },
          n.zone != null ? { zone = n.zone } : {}
        )
        if contains(n.groups, group)
      }
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename        = var.inventory_path
  file_permission = "0644"
  content         = yamlencode(local.inventory)
}
