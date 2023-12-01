terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  service_account_key_file = "./authorized_key.json"
  folder_id                = local.folder_id
  zone                     = "ru-central1-a"
}

resource "yandex_vpc_network" "foo" {}

resource "yandex_vpc_subnet" "foo" {
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.foo.id
  v4_cidr_blocks = ["10.5.0.0/24"]
}

resource "yandex_container_registry" "registry1" {
  name = "registry1"
}

locals {
  folder_id = "b1gufgphuc6t73bgr8ja"
  service-accounts = toset([
    "catgpt-sa",
    "tf-sa",
    "catgpt-ig-sa"
  ])
  catgpt-sa-roles = toset([
    "container-registry.images.puller",
    "monitoring.editor",
  ])
  tf-sa-roles = toset([
    "admin",
  ])
  catgpt-ig-sa-roles = toset([
    "compute.editor",
    "iam.serviceAccounts.user",
    "load-balancer.admin",
    "vpc.publicAdmin",
    "vpc.user",
  ])
}

resource "yandex_iam_service_account" "service-accounts" {
  for_each = local.service-accounts
  name     = "${local.folder_id}-${each.key}"
}

resource "yandex_resourcemanager_folder_iam_member" "catgpt-roles" {
  for_each  = local.catgpt-sa-roles
  folder_id = local.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.service-accounts["catgpt-sa"].id}"
  role      = each.key
}

resource "yandex_resourcemanager_folder_iam_member" "tf-roles" {
  for_each  = local.tf-sa-roles
  folder_id = local.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.service-accounts["tf-sa"].id}"
  role      = each.key
}

resource "yandex_resourcemanager_folder_iam_member" "catgpt-ig-roles" {
  for_each  = local.catgpt-ig-sa-roles
  folder_id = local.folder_id
  member    = "serviceAccount:${yandex_iam_service_account.service-accounts["catgpt-ig-sa"].id}"
  role      = each.key
}

data "yandex_compute_image" "coi" {
  family = "container-optimized-image"
}

resource "yandex_compute_instance_group" "catgpt-ig" {
  depends_on = [
    yandex_resourcemanager_folder_iam_member.catgpt-ig-roles
  ]
  name                = "catgpt-ig"
  folder_id           = local.folder_id
  service_account_id  =  yandex_iam_service_account.service-accounts["catgpt-ig-sa"].id
  instance_template {
    platform_id        = "standard-v2"
    service_account_id = yandex_iam_service_account.service-accounts["catgpt-sa"].id
    resources {
      cores         = 2
      memory        = 1
      core_fraction = 5
    }
    scheduling_policy {
      preemptible = true
    }
    network_interface {
      subnet_ids = [ yandex_vpc_subnet.foo.id ]
      nat = true
    }
    boot_disk {
      initialize_params {
        type = "network-hdd"
        size = "30"
        image_id = data.yandex_compute_image.coi.id
      }
    }
    metadata = {
      docker-compose = templatefile("${path.module}/docker-compose.yaml", {
        folder_id = local.folder_id
        registry_id = yandex_container_registry.registry1.id
      })
      ssh-keys  = "ubuntu:${file("~/.ssh/id_ed25519.pub")}"
      user-data = file("${path.module}/cloud-config.yaml")
    }
  }

  scale_policy {
    fixed_scale {
      size = 3
    }
  }

  deploy_policy {
    max_unavailable = 1
    max_creating    = 3
    max_expansion   = 2
    max_deleting    = 3
  }

  allocation_policy {
    zones = ["ru-central1-a"]
  }

  load_balancer {
    target_group_name = "catgpt"
  }
}

resource "yandex_lb_network_load_balancer" "lb-catgpt" {
  name = "lb-catgpt"

  listener {
    name        = "cat-listener"
    port        = 80
    target_port = 8080
    external_address_spec {
      ip_version = "ipv4"
    }
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.catgpt-ig.load_balancer[0].target_group_id

    healthcheck {
      name = "http"
      http_options {
        port = 8080
        path = "/ping"
      }
    }
  }
}
