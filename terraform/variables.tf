variable "cloud" {
  description = "Entrada do clouds.yaml usada pelo provider"
  type        = string
  default     = "larcerto-devops1"
}

variable "external_network" {
  description = "Rede externa criada pelo bootstrap (172.24.4.0/24 na br-ex)"
  type        = string
  default     = "public"
}

variable "image" {
  type    = string
  default = "ubuntu-22.04"
}

variable "flavor" {
  type    = string
  default = "ds1G"
}

variable "public_key_path" {
  description = "Chave publica SSH do devops1 (a privada fica no host)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "private_key_path" {
  description = "Chave privada correspondente, usada pelo Ansible"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "subnet_cidr" {
  type    = string
  default = "10.11.12.0/24"
}

# IP fixo por VM: o DNS da subnet e o registro db.larcerto.com.br dependem deles.
variable "vms" {
  description = "VMs da topologia completa (REQ09): nome => IP privado e security groups"
  type = map(object({
    ip  = string
    sgs = list(string)
  }))
  default = {
    dns = { ip = "10.11.12.10", sgs = ["ssh", "ping", "dns"] }
    ca  = { ip = "10.11.12.11", sgs = ["ssh", "ping"] }
    db  = { ip = "10.11.12.12", sgs = ["ssh", "ping", "db"] }
    web = { ip = "10.11.12.13", sgs = ["ssh", "ping", "web"] }
  }
}
