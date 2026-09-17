output "inventory_path" {
  value       = local_file.ansible_inventory.filename
  description = "Generated Ansible inventory"
}

output "addresses" {
  value       = { for name, n in var.nodes : name => n.address }
  description = "hostname → address, for anything downstream that needs it"
}

output "groups" {
  value       = local.all_groups
  description = "Ansible groups derived from the fleet definition"
}

# Handy during a rollout: terraform output -raw ssh_config >> ~/.ssh/config
output "ssh_config" {
  value = join("\n", [
    for name, n in var.nodes :
    "Host ${name}\n  HostName ${n.address}\n  User ${coalesce(n.user, var.default_user)}"
  ])
}
