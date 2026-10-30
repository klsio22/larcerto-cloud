output "vms" {
  description = "IP privado e floating IP de cada VM"
  value = {
    for k, v in var.vms : k => {
      private  = v.ip
      floating = openstack_networking_floatingip_v2.fip[k].address
    }
  }
}
