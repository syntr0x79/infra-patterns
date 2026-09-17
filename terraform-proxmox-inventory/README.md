# Terraform provisions the VMs and writes the Ansible inventory

One map describes the fleet. Terraform creates the machines from it and generates the Ansible inventory from the same map, so provisioning and configuration cannot disagree.

```hcl
nodes = {
  "k8s-worker-9" = {
    hypervisor = "hypervisor-2"
    address    = "10.0.0.108"
    cores      = 8
    memory     = 32768
    disk_gb    = 200
    groups     = ["k8s", "kube_node"]
    zone       = "site-b"
  }
}
```

```bash
terraform apply
ansible-playbook -i ../ansible/inventory/hosts.yml site.yml
```

## The problem it removes

The ordinary setup has two sources of truth: Terraform knows which VMs exist, and a hand-maintained inventory knows which hosts Ansible manages. They agree on the day they are written. Then someone adds a worker in a hurry, or decommissions one, and the two drift — usually discovered months later as "why was this host never patched" or a playbook failing against an address that belongs to something else now.

Generating one from the other makes the drift impossible rather than detectable. A machine that exists has an inventory entry because the same `for_each` produced both.

## Generated inventory

`terraform apply` writes:

```yaml
k8s:
  hosts:
    k8s-manager-1:
      ansible_host: 10.0.0.10
      ansible_user: ubuntu
      zone: site-a
    k8s-worker-9:
      ansible_host: 10.0.0.108
      ansible_user: ubuntu
      zone: site-b
kube_control_plane:
  hosts:
    k8s-manager-1: {ansible_host: 10.0.0.10, ansible_user: ubuntu, zone: site-a}
patroni:
  hosts:
    db-1: {ansible_host: 10.0.0.200, ansible_user: ubuntu, zone: site-a}
    db-2: {ansible_host: 10.0.0.201, ansible_user: ubuntu, zone: site-b}
```

Group names are chosen to match what kubespray expects (`kube_control_plane`, `kube_node`, `etcd`), so the same generated file drives a cluster build without translation.

The `zone` variable propagates through as a host variable — the same zone the [cross-DC watchdog](../k8s-cross-dc-zone-affinity/) reads off node labels. Deriving both from one definition means the two views of "which site is this machine in" cannot disagree either.

## Two details that matter in practice

**`ignore_changes = [disk, initialization]`.** After first boot the guest OS owns its disk. Without this, editing the cloud-init template — which happens — turns the next `terraform apply` into a fleet rebuild. Terraform is used here to *create* machines, not to keep asserting their internal state; that is Ansible's job, and the boundary should be explicit.

**Validation rules instead of comments.** A node with no groups is rejected at plan time, as is a duplicate address:

```
Every node must belong to at least one Ansible group; a host nobody manages
is how drift starts.
```

A convention documented in a README is a convention that gets broken under time pressure. The same convention expressed as a `validation` block simply fails.

## State

Terraform state holds VM addresses and the provider API token, so it belongs in an encrypted remote backend. `versions.tf` has the shape commented out; `.gitignore` keeps `*.tfstate` and real `tfvars` out of the repository, with `*.tfvars.example` explicitly allowed back in.

## Files

```
versions.tf              providers, backend shape
variables.tf             the fleet type and its validation rules
main.tf                  VMs + inventory generation
outputs.tf               inventory path, addresses, groups, ssh_config
terraform.tfvars.example a five-node two-site fleet
```

`terraform output -raw ssh_config >> ~/.ssh/config` is worth it during a rollout — the machines you just created become reachable by name.

## Adapting it

The provider is `bpg/proxmox`, but nothing about the pattern is Proxmox-specific: the inventory generation is `local_file` + `yamlencode` over a `for_each` map, which works the same against any provider. Swapping the `proxmox_virtual_environment_vm` resource for a cloud instance leaves `locals.inventory` untouched.
