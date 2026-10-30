# Infra do projeto larcerto (como devops1): rede privada, router, keypair,
# security groups, 4 VMs com IP fixo e floating IP na rede public.
# Sem Cinder neste lab: as VMs fazem boot da imagem (disco do flavor), nao de volume.

data "openstack_networking_network_v2" "public" {
  name = var.external_network
}

resource "openstack_networking_network_v2" "net" {
  name           = "larcerto-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "subnet" {
  name       = "larcerto-subnet"
  network_id = openstack_networking_network_v2.net.id
  cidr       = var.subnet_cidr
  ip_version = 4
  gateway_ip = cidrhost(var.subnet_cidr, 1)
  # 1o a VM dns; o 8.8.8.8 cobre o boot, antes do bind9 estar configurado.
  dns_nameservers = [var.vms["dns"].ip, "8.8.8.8"]

  allocation_pool {
    start = cidrhost(var.subnet_cidr, 100)
    end   = cidrhost(var.subnet_cidr, 200)
  }
}

resource "openstack_networking_router_v2" "router" {
  name                = "larcerto-router"
  external_network_id = data.openstack_networking_network_v2.public.id
}

resource "openstack_networking_router_interface_v2" "router_if" {
  router_id = openstack_networking_router_v2.router.id
  subnet_id = openstack_networking_subnet_v2.subnet.id
}

resource "openstack_compute_keypair_v2" "devops1" {
  name       = "devops1"
  public_key = file(pathexpand(var.public_key_path))
}

# ---------------------------------------------------------------- security groups

locals {
  # nome => lista de regras { proto, port, cidr }
  secgroups = {
    ssh  = [{ proto = "tcp", port = 22, cidr = "0.0.0.0/0" }]
    ping = [{ proto = "icmp", port = 0, cidr = "0.0.0.0/0" }]
    web = [
      { proto = "tcp", port = 80, cidr = "0.0.0.0/0" },
      { proto = "tcp", port = 443, cidr = "0.0.0.0/0" },
    ]
    dns = [
      { proto = "udp", port = 53, cidr = "0.0.0.0/0" },
      { proto = "tcp", port = 53, cidr = "0.0.0.0/0" },
    ]
    # MariaDB so a partir da rede privada (a web); o host nao alcanca.
    db = [{ proto = "tcp", port = 3306, cidr = var.subnet_cidr }]
  }

  sg_rules = merge([
    for sg, rules in local.secgroups : {
      for r in rules : "${sg}-${r.proto}-${r.port}" => merge(r, { sg = sg })
    }
  ]...)
}

resource "openstack_networking_secgroup_v2" "sg" {
  for_each    = local.secgroups
  name        = each.key
  description = "LarCerto - ${each.key}"
}

resource "openstack_networking_secgroup_rule_v2" "rule" {
  for_each          = local.sg_rules
  security_group_id = openstack_networking_secgroup_v2.sg[each.value.sg].id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value.proto
  port_range_min    = each.value.proto == "icmp" ? null : each.value.port
  port_range_max    = each.value.proto == "icmp" ? null : each.value.port
  remote_ip_prefix  = each.value.cidr
}

# ---------------------------------------------------------------- VMs

resource "openstack_networking_port_v2" "port" {
  for_each   = var.vms
  name       = "${each.key}-port"
  network_id = openstack_networking_network_v2.net.id
  security_group_ids = [
    for sg in each.value.sgs : openstack_networking_secgroup_v2.sg[sg].id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.subnet.id
    ip_address = each.value.ip
  }
}

resource "openstack_compute_instance_v2" "vm" {
  for_each    = var.vms
  name        = each.key
  image_name  = var.image
  flavor_name = var.flavor
  key_pair    = openstack_compute_keypair_v2.devops1.name

  network {
    port = openstack_networking_port_v2.port[each.key].id
  }

  depends_on = [openstack_networking_router_interface_v2.router_if]
}

resource "openstack_networking_floatingip_v2" "fip" {
  for_each = var.vms
  pool     = var.external_network
}

resource "openstack_networking_floatingip_associate_v2" "fip" {
  for_each    = var.vms
  floating_ip = openstack_networking_floatingip_v2.fip[each.key].address
  port_id     = openstack_networking_port_v2.port[each.key].id

  depends_on = [openstack_compute_instance_v2.vm]
}

# Inventario do Ansible gerado a partir dos IPs reais.
resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/hosts.ini.tftpl", {
    vms              = var.vms
    fips             = { for k, f in openstack_networking_floatingip_v2.fip : k => f.address }
    private_key_path = pathexpand(var.private_key_path)
  })
}
