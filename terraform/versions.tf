terraform {
  required_version = ">= 1.5"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Credenciais do devops1 via clouds.yaml gerado pelo cloud/bootstrap.sh
# (OS_CLIENT_CONFIG_FILE=cloud/secrets/clouds.yaml), em vez de senha no .tf.
provider "openstack" {
  cloud = var.cloud
}
