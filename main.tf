variable "google_project" {
  type    = string
}

variable "google_project_dns" {
  type    = string
}

variable "google_dns_managed_zone" {
  type    = string
}

variable "google_region" {
  type    = string
}

variable "google_zone" {
  type    = string
}

variable "videobridge_git_commit_sha" {
  type    = string
  default = "08409457bcbe18665717e3da77b06d9ddd8d4303"
}

variable "api_host" {
  type    = string
}

variable "web_host" {
  type    = string
}

variable "image_resizer_host" {
  type    = string
}

variable "datatrack_host" {
  type    = string
}

variable "jvbuster_host" {
  type    = string
}

variable "rtp_audio_processor_host" {
  type    = string
}



locals {
  rabbitmq_user    = "rabbit"
  neo4j_user       = "neo4j" # DO NOT CHANGE, hardcoded in helm
  primary_db_user  = "primary-db"
  jvbuster_db_user = "jvbuster"

  gke_node_network_tag = "gke-node"
  videobridge_network_tag = "videobridge"
}

resource "random_id" "deployment" {
  byte_length = 8
}

provider "google" {
  project = var.google_project
  region  = var.google_region
  zone    = var.google_zone
}

provider "google" {
  alias   = "dns"
  project = var.google_project_dns
}

data "google_dns_managed_zone" "default" {
  provider = google.dns
  name     = var.google_dns_managed_zone
}

data "google_compute_network" "default" {
  name = "default"
}

resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = data.google_compute_network.default.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = data.google_compute_network.default.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

resource "google_service_account" "default" {
  account_id   = "service-account-id"
  display_name = "Service Account"
}

resource "google_service_account_key" "default" {
  service_account_id = google_service_account.default.name
}

resource "google_container_cluster" "primary" {
  name = "cluster-${random_id.deployment.hex}"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "/16"
    services_ipv4_cidr_block = "/16"
  }

  addons_config {
    http_load_balancing {
      disabled = true
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_container_node_pool" "primary_preemptible_nodes" {
  name    = "node-pool-${random_id.deployment.hex}"
  cluster = google_container_cluster.primary.name

  autoscaling {
    min_node_count = "3"
    max_node_count = "5"
  }

  node_config {
    preemptible  = true
    machine_type = "n1-standard-2"
    tags = [local.gke_node_network_tag]

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.default.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

data "google_client_config" "default" {
}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth.0.cluster_ca_certificate)
}

resource "kubernetes_storage_class" "ssd" {
  metadata {
    name = "ssd"
  }
  storage_provisioner = "kubernetes.io/gce-pd"
  reclaim_policy      = "Delete"
  parameters = {
    type = "pd-ssd"
  }
}

# DEPRECATED
# Workload Identity is the recommended way of accessing Google Cloud APIs from pods.
# https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
resource "kubernetes_secret" "google_bucket_credentials" {
  metadata {
    name = "google-bucket-credentials"
  }

  data = {
    "key.json" = base64decode(google_service_account_key.default.private_key)
  }
}

provider "helm" {
  kubernetes {
    host                   = google_container_cluster.primary.endpoint
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth.0.cluster_ca_certificate)
  }
}

resource "helm_release" "cert-manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  #   version    = "1.7.1"

  namespace        = "cert-manager"
  create_namespace = true

  depends_on = [google_container_node_pool.primary_preemptible_nodes]

  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "ingress-nginx"
  chart      = "ingress-nginx"

  namespace        = "ingress-nginx"
  create_namespace = true

  timeout    = 600
  depends_on = [helm_release.cert-manager]

  set {
    # handle client ip
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }
}

resource "helm_release" "clusterissuer_letsencrypt" {
  name  = "clusterissuer-letsencrypt"
  chart = "./tf-data/clusterissuer-letsencrypt"

  depends_on = [helm_release.cert-manager]

  set {
    name  = "email"
    value = "dev@connect.club"
  }
}

resource "random_password" "rabbitmq" {
  length  = 8
  special = false
}

resource "helm_release" "rabbitmq" {
  name       = "rabbitmq"
  repository = "https://raw.githubusercontent.com/bitnami/charts/archive-full-index/bitnami"
  chart      = "rabbitmq"
  version    = "6.25.11"

  timeout = 600

  depends_on = [
    google_container_node_pool.primary_preemptible_nodes,
    kubernetes_storage_class.ssd
  ]

  values = [
    "${file("tf-data/rabbitmq/values.yaml")}",
    "${file("tf-data/rabbitmq/values-stage.yaml")}"
  ]

  set {
    name  = "metrics.enabled"
    value = "false"
  }

  set {
    name  = "rabbitmq.username"
    value = local.rabbitmq_user
  }

  set {
    name  = "rabbitmq.password"
    value = random_password.rabbitmq.result
  }
}

resource "random_password" "neo4j" {
  length  = 8
  special = false
}

resource "helm_release" "neo4j" {
  name  = "neo4j"
  chart = "https://github.com/neo4j-contrib/neo4j-helm/releases/download/4.4.3/neo4j-4.4.3.tgz"

  timeout = 600

  depends_on = [
    google_container_node_pool.primary_preemptible_nodes,
    kubernetes_storage_class.ssd
  ]

  values = [
    "${file("tf-data/neo4j/values.yaml")}",
    "${file("tf-data/neo4j/values-stage.yaml")}"
  ]

  set {
    name  = "metrics.prometheus.enabled"
    value = "false"
  }

  set {
    name  = "neo4jPassword"
    value = random_password.neo4j.result
  }
}

resource "helm_release" "elasticsearch" {
  name       = "elasticsearch"
  repository = "https://helm.elastic.co"
  chart      = "elasticsearch"
  version    = "7.13.1"

  timeout = 600

  depends_on = [
    google_container_node_pool.primary_preemptible_nodes
  ]

  values = [
    "${file("tf-data/elasticsearch/values-stage.yaml")}"
  ]
}

resource "google_redis_instance" "default" {
  name           = "redis-${random_id.deployment.hex}"
  redis_version  = "REDIS_5_0"
  memory_size_gb = 1
}

resource "google_pubsub_topic" "datatrack" {
  name = "datatrack"
}

resource "google_storage_bucket" "api_files" {
  name     = "api-files-${random_id.deployment.hex}"
  location = var.google_region
  force_destroy = true
}

resource "google_storage_bucket_iam_binding" "api_files_public_rule" {
  bucket = google_storage_bucket.api_files.name
  role   = "roles/storage.objectViewer"
  members = [
    "allUsers",
  ]
}

resource "google_storage_bucket_iam_binding" "api_files_service_rule" {
  bucket = google_storage_bucket.api_files.name
  role   = "roles/storage.admin"
  members = [
    "serviceAccount:${google_service_account.default.email}"
  ]
}

resource "google_storage_bucket_object" "multiroom-photo" {
  source = "./gcs-data/api-files/1c387701-9e37-431a-8002-94636fe72b4f.jpg"
  name   = "1c387701-9e37-431a-8002-94636fe72b4f.jpg"
  bucket = google_storage_bucket.api_files.name
}

resource "google_storage_bucket_object" "gallery-room-photo" {
  source = "./gcs-data/api-files/36b9dc26-1bf0-4be2-a494-a44b42026dfd.jpg"
  name   = "36b9dc26-1bf0-4be2-a494-a44b42026dfd.jpg"
  bucket = google_storage_bucket.api_files.name
}

resource "google_storage_bucket_object" "small-broadcasting-room-photo" {
  source = "./gcs-data/api-files/45f80f11-832c-47dc-9e48-4b9776de5fae.jpg"
  name   = "45f80f11-832c-47dc-9e48-4b9776de5fae.jpg"
  bucket = google_storage_bucket.api_files.name
}

resource "google_storage_bucket_object" "large-broadcasting-room-photo" {
  source = "./gcs-data/api-files/021da593-e6f0-46d6-b610-b0afb03304a4.jpg"
  name   = "021da593-e6f0-46d6-b610-b0afb03304a4.jpg"
  bucket = google_storage_bucket.api_files.name
}

resource "google_storage_bucket_object" "small-networking-room-photo" {
  source = "./gcs-data/api-files/314009d4-fed1-4375-b865-e0816ca2f1b5.jpg"
  name   = "314009d4-fed1-4375-b865-e0816ca2f1b5.jpg"
  bucket = google_storage_bucket.api_files.name
}

resource "google_storage_bucket_object" "large-networking-room-photo" {
  source = "./gcs-data/api-files/f9ecedc9-cefe-4174-b1ae-60258c4f955c.jpg"
  name   = "f9ecedc9-cefe-4174-b1ae-60258c4f955c.jpg"
  bucket = google_storage_bucket.api_files.name
}

resource "google_storage_bucket" "mobile_app_logs" {
  name     = "mobile-app-logs-${random_id.deployment.hex}"
  location = var.google_region
}

resource "google_sql_database_instance" "primary" {
  name             = "primary-instance-${random_id.deployment.hex}"
  database_version = "POSTGRES_11"

  depends_on = [google_service_networking_connection.private_vpc_connection]

  deletion_protection = false

  settings {
    tier = "db-f1-micro"
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.default.id
    }
  }
}

resource "random_password" "primary_db_user" {
  length  = 8
  special = false
}

resource "google_sql_user" "primary_db_user" {
  instance = google_sql_database_instance.primary.name
  name     = local.primary_db_user
  password = random_password.primary_db_user.result
}

resource "google_sql_database" "api_db" {
  instance = google_sql_database_instance.primary.name
  name     = "api_db"
  depends_on = [
    google_sql_user.primary_db_user
  ]
}

resource "google_sql_database_instance" "jvbuster" {
  name             = "jvbuster-instance-${random_id.deployment.hex}"
  database_version = "MYSQL_5_7"

  depends_on = [google_service_networking_connection.private_vpc_connection]

  deletion_protection = false

  settings {
    tier = "db-f1-micro"
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.default.id
    }
  }
}

resource "random_password" "jvbuster_db_user" {
  length  = 8
  special = false
}

resource "google_sql_user" "jvbuster_db_user" {
  instance = google_sql_database_instance.jvbuster.name
  name     = local.jvbuster_db_user
  password = random_password.jvbuster_db_user.result
}

resource "google_sql_database" "jvbuster_db" {
  instance = google_sql_database_instance.jvbuster.name
  name     = "jvbuster"
  depends_on = [
    google_sql_user.jvbuster_db_user
  ]
}

resource "kubernetes_endpoints" "primary_db" {
  depends_on = [google_container_node_pool.primary_preemptible_nodes]
  metadata {
    name = "primary-db"
  }

  subset {
    address {
      ip = google_sql_database_instance.primary.private_ip_address
    }

    port {
      port     = 5432
      protocol = "TCP"
    }
  }
}

resource "kubernetes_service" "primary_db" {
  metadata {
    name = kubernetes_endpoints.primary_db.metadata.0.name
  }
  spec {
    port {
      port        = 5432
      target_port = 5432
    }
    type = "LoadBalancer"
  }
}

resource "tls_private_key" "jwt" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "helm_release" "api" {
  name  = "api"
  chart = "./tf-data/api"

  depends_on = [
    kubernetes_secret.google_bucket_credentials,
    helm_release.rabbitmq,
    helm_release.elasticsearch,
    google_redis_instance.default,
    google_sql_database_instance.primary,
    google_sql_user.primary_db_user,
    google_sql_database.api_db
  ]

  values = [
    "${file("tf-data/api/values.yaml")}",
    "${file("tf-data/api/values-stage.yaml")}"
  ]

  set {
    name  = "config.LOCK_DSN"
    value = "redis://${google_redis_instance.default.host}:${google_redis_instance.default.port}"
  }

  set {
    name  = "config.REDIS_URL"
    value = "redis://${google_redis_instance.default.host}:${google_redis_instance.default.port}"
  }

  set {
    name  = "config.ELASTICSEARCH_HOST"
    value = "http://${helm_release.elasticsearch.name}-master:9200"
  }

  set {
    name  = "config.MESSENGER_TRANSPORT_DSN"
    value = "amqp://${local.rabbitmq_user}:${random_password.rabbitmq.result}@${helm_release.rabbitmq.name}:5672/%2f/messages"
  }

  set {
    name  = "config.IMAGE_RESIZER_BASE_URL"
    value = "https://${var.image_resizer_host}"
  }

  set {
    name  = "config.PEOPLE_MATCHING_URL"
    value = "http://peoplematchingbackend"
  }

  set {
    name = "config.JWT_TOKEN_PRIVATE_KEY"
    value = tls_private_key.jwt.private_key_pem
  }

  set {
    name = "config.JITSI_SERVER"
    value = "https://${var.jvbuster_host}"
  }

  set {
    name = "config.DATATRACK_URL"
    value = "wss://${var.datatrack_host}/ws"
  }

  set {
    name = "config.DATATRACK_API_URL"
    value = "http://datatrack:8083"
  }

  set {
    name = "config.AMPLITUDE_ENABLE"
    value = "0"
    type = "string"
  }

  set {
    # disable creation of postgresql in cluster
    name  = "postgresql.enabled"
    value = false
  }

  set {
    name  = "postgresql.nameOverride"
    value = google_sql_database_instance.primary.private_ip_address
  }

  set {
    name  = "postgresql.postgresqlDatabase"
    value = google_sql_database.api_db.name
  }

  set {
    name  = "postgresql.postgresqlUsername"
    value = google_sql_user.primary_db_user.name
  }

  set {
    name  = "postgresql.postgresqlPassword"
    value = google_sql_user.primary_db_user.password
  }

  set {
    name  = "config.GOOGLE_CLOUD_STORAGE_BUCKET"
    value = google_storage_bucket.api_files.name
  }

  set {
    name  = "config.GOOGLE_CLOUD_STORAGE_BUCKET_MOBILE_APP_LOGS"
    value = google_storage_bucket.mobile_app_logs.name
  }

  set {
    name  = "ingress.hosts.main"
    value = var.api_host
  }
}

resource "time_sleep" "wait_api_load_balancer" {
  depends_on = [helm_release.api]

  create_duration = "5m"
}

data "kubernetes_ingress_v1" "api_ingress" {
  metadata {
    name = "api"
  }
  depends_on = [time_sleep.wait_api_load_balancer]
}

resource "google_dns_record_set" "api" {
  provider     = google.dns
  name         = "${var.api_host}."
  managed_zone = data.google_dns_managed_zone.default.name
  type         = "A"
  ttl          = 300

  rrdatas = [data.kubernetes_ingress_v1.api_ingress.status.0.load_balancer.0.ingress.0.ip]
}

resource "helm_release" "nginx_resizer" {
  name  = "nginx-resizer"
  chart = "./tf-data/nginx-resizer"

  values = [
    "${file("tf-data/nginx-resizer/values.yaml")}"
  ]

  set {
    name  = "ingressHosts.main"
    value = var.image_resizer_host
  }

  set {
    name  = "storageBucket"
    value = google_storage_bucket.api_files.name
  }
}

resource "time_sleep" "wait_nginx_resizer_load_balancer" {
  depends_on = [helm_release.nginx_resizer]

  create_duration = "5m"
}

data "kubernetes_ingress_v1" "nginx_resizer_ingress" {
  metadata {
    name = "nginx-resizer"
  }
  depends_on = [time_sleep.wait_nginx_resizer_load_balancer]
}

resource "google_dns_record_set" "nginx_resizer" {
  provider     = google.dns
  name         = "${var.image_resizer_host}."
  managed_zone = data.google_dns_managed_zone.default.name
  type         = "A"
  ttl          = 300

  rrdatas = [data.kubernetes_ingress_v1.nginx_resizer_ingress.status.0.load_balancer.0.ingress.0.ip]
}

resource "helm_release" "peoplematchingbackend" {
  name  = "peoplematchingbackend"
  chart = "./tf-data/peoplematchingbackend"

  depends_on = [
    helm_release.api,
    helm_release.rabbitmq,
    helm_release.neo4j,
    google_sql_database_instance.primary,
    google_sql_user.primary_db_user,
    google_sql_database.api_db
  ]

  values = [
    "${file("tf-data/peoplematchingbackend/values.yaml")}",
    "${file("tf-data/peoplematchingbackend/values-stage.yaml")}"
  ]

  set {
    name  = "envs.IMAGE_RESIZER_BASE_URL"
    value = "https://${var.image_resizer_host}"
  }

  set {
    name  = "config.MESSENGER_TRANSPORT_DSN"
    value = "amqp://${local.rabbitmq_user}:${random_password.rabbitmq.result}@${helm_release.rabbitmq.name}:5672/%2f"
  }

  set {
    name  = "config.POSTGRES_HOST"
    value = google_sql_database_instance.primary.private_ip_address
  }

  set {
    name  = "config.POSTGRES_USER"
    value = google_sql_user.primary_db_user.name
  }

  set {
    name  = "config.POSTGRES_PASS"
    value = google_sql_user.primary_db_user.password
  }

  set {
    name  = "config.POSTGRES_DB"
    value = google_sql_database.api_db.name
  }

  set {
    name  = "config.NEO4J_URL"
    value = "neo4j://${helm_release.neo4j.name}"
  }

  set {
    name  = "config.NEO4J_USER"
    value = local.neo4j_user
  }

  set {
    name  = "config.NEO4J_PASS"
    value = random_password.neo4j.result
  }
}


resource "helm_release" "web" {
  name  = "web"
  chart = "./tf-data/web"

  depends_on = [
    helm_release.api,
    google_sql_database_instance.primary,
    google_sql_user.primary_db_user,
    google_sql_database.api_db
  ]

  values = [
    "${file("tf-data/web/values.yaml")}",
    "${file("tf-data/web/values-stage.yaml")}",
  ]

  set {
    name  = "config.API_PATH"
    value = "https://${var.api_host}" # do not put here link to k8s service
  }

  set {
    name = "config.PICS_DOMAIN"
    value = var.image_resizer_host
  }

  set {
    name  = "config.POSTGRES_MAIN_HOST"
    value = google_sql_database_instance.primary.private_ip_address
  }

  set {
    name  = "config.POSTGRES_MAIN_DB"
    value = google_sql_database.api_db.name
  }

  set {
    name  = "config.POSTGRES_MAIN_USER"
    value = google_sql_user.primary_db_user.name
  }

  set {
    name  = "config.POSTGRES_MAIN_PASS"
    value = google_sql_user.primary_db_user.password
  }

  set {
    name  = "ingress.host"
    value = var.web_host
  }

  set {
    name  = "pdb.enabled"
    value = "false"
  }
}

resource "time_sleep" "wait_web_load_balancer" {
  depends_on = [helm_release.web]

  create_duration = "5m"
}

data "kubernetes_ingress_v1" "web_ingress" {
  metadata {
    name = "web-connectclub-web"
  }
  depends_on = [time_sleep.wait_web_load_balancer]
}

resource "google_dns_record_set" "web" {
  provider     = google.dns
  name         = "${var.web_host}."
  managed_zone = data.google_dns_managed_zone.default.name
  type         = "A"
  ttl          = 300

  rrdatas = [data.kubernetes_ingress_v1.web_ingress.status.0.load_balancer.0.ingress.0.ip]
}

resource "helm_release" "datatrack" {
  name  = "datatrack"
  chart = "./tf-data/datatrack"

  values = ["${file("tf-data/datatrack/values.yaml")}"]

  set {
    name  = "config.GCLOUD_PROJECT_ID"
    value = var.google_project
  }

  set {
    name  = "config.DATATRACK_APIURL"
    value = "https://${var.api_host}"
  }

  set {
    name = "config.DISABLE_NEWRELIC"
    value = "true"
    type = "string"
  }

  set {
    name  = "ingress.hosts.main"
    value = var.datatrack_host
  }

  set {
    name  = "serviceMonitor.enabled"
    value = false
  }
}

resource "time_sleep" "wait_datatrack_load_balancer" {
  depends_on = [helm_release.datatrack]

  create_duration = "5m"
}

data "kubernetes_ingress_v1" "datatrack_ingress" {
  metadata {
    name = "datatrack"
  }
  depends_on = [time_sleep.wait_datatrack_load_balancer]
}

resource "google_dns_record_set" "datatrack" {
  provider     = google.dns
  name         = "${var.datatrack_host}."
  managed_zone = data.google_dns_managed_zone.default.name
  type         = "A"
  ttl          = 300

  rrdatas = [data.kubernetes_ingress_v1.datatrack_ingress.status.0.load_balancer.0.ingress.0.ip]
}

resource "null_resource" "packer_videobridge_builder" {
  provisioner "local-exec" {
    working_dir = "./packer"
    environment = {
      PROJECT_ID     = var.google_project
      ZONE           = var.google_zone
      GIT_COMMIT_SHA = var.videobridge_git_commit_sha
    }
    command = "packer build -var project_id=\"$PROJECT_ID\" -var zone=\"$ZONE\" -var git_commit_sha=\"$GIT_COMMIT_SHA\" packer.json"
  }
}

resource "google_project_iam_custom_role" "jvbuster" {
  role_id     = "jvbusterRole"
  title       = "Jvbuster Custom Role"
  description = "A description"
  permissions = [
    "compute.instances.create",
    "compute.instances.delete",
    "compute.instances.setMetadata",
    "compute.instances.setTags",
    "compute.instances.setLabels",
    "compute.instances.list",
    "compute.disks.create",
    "compute.disks.get",
    "compute.subnetworks.use",
    "compute.subnetworks.useExternalIp",
    "compute.images.useReadOnly"
  ]
}

resource "google_project_iam_binding" "jvbuster" {
  project = var.google_project
  role    = google_project_iam_custom_role.jvbuster.id

  members = [
    "serviceAccount:${google_service_account.default.email}"
  ]
}

data "google_compute_subnetwork" "default" {
  name   = "default"
  region = var.google_region
  depends_on = [
    google_container_node_pool.primary_preemptible_nodes
  ]
}

resource "google_compute_firewall" "videobridge_private" {
  project     = var.google_project
  name        = "videobridge-firewall-private-rule"
  network     = data.google_compute_network.default.name
  description = "Creates firewall rule targeting videobridge instances"

  allow {
    protocol  = "tcp"
    ports     = ["8080","9100"]
  }

  allow {
    protocol = "udp"
    ports    = ["4096"]
  }

  source_ranges = [
    data.google_compute_subnetwork.default.ip_cidr_range,
    data.google_compute_subnetwork.default.secondary_ip_range.0.ip_cidr_range,
    data.google_compute_subnetwork.default.secondary_ip_range.1.ip_cidr_range
  ]
  target_tags   = [local.videobridge_network_tag]
}

resource "google_compute_firewall" "videobridge_public" {
  project     = var.google_project
  name        = "videobridge-firewall-public-rule"
  network     = data.google_compute_network.default.name
  description = "Creates firewall rule targeting videobridge instances"

  allow {
    protocol = "udp"
    ports    = ["10000"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags = [local.videobridge_network_tag]
}

resource "helm_release" "jvbuster" {
  name  = "jvbuster"
  chart = "./tf-data/jvbuster"

  values = [
    "${file("tf-data/jvbuster/values.yaml")}",
    "${file("tf-data/jvbuster/values-stage.yaml")}"
  ]

  depends_on = [
    null_resource.packer_videobridge_builder
  ]

  set {
    name  = "config.REDIS_HOST"
    value = google_redis_instance.default.host
  }

  set {
    name  = "config.MYSQL_HOST"
    value = google_sql_database_instance.jvbuster.private_ip_address
  }

  set {
    name  = "config.MYSQL_USERNAME"
    value = google_sql_user.jvbuster_db_user.name
  }

  set {
    name  = "config.MYSQL_PASSWORD"
    value = google_sql_user.jvbuster_db_user.password
  }

  set {
    name  = "config.GCLOUD_JVB_PROJECT"
    value = var.google_project
  }

  set {
    name  = "config.GCLOUD_JVB_ZONE"
    value = var.google_zone
  }

  set {
    name  = "config.GCLOUD_JVB_DISK-SOURCE-IMAGE_PROJECT"
    value = var.google_project
  }

  set {
    name  = "config.GCLOUD_JVB_DISK-SOURCE-IMAGE"
    value = "videobridge-${var.videobridge_git_commit_sha}"
  }

  set {
    name  = "config.GCLOUD_JVB_SUBNET"
    value = "default"
  }

  set {
    name  = "config.JVB_CONFERENCE_NOTIFICATION_URL"
    value = "https://${var.api_host}/api/v2/video-room/event"
  }

  set {
    name  = "config.JVB_STATISTIC_NOTIFICATION_URL"
    value = "https://${var.jvbuster_host}/statistic"
  }

  set {
    name  = "config.SPRING_PROFILES_ACTIVE"
    value = "gcloud-jvb"
  }

  set {
    name  = "config.JVB_MACHINE_TYPE"
    value = "c2d-highcpu-2"
  }

  set {
    name  = "config.JVB_MACHINE_ENDPOINTS_CAPACITY"
    value = "20"
  }

  set {
    name  = "config.JVB_AUDIO_PROCESSOR_HTTP_URL"
    value = "https://${var.rtp_audio_processor_host}/"
  }

  set {
    name  = "config.JVB_AUDIO_PROCESSOR_IP"
    value = "127.0.0.1"
  }

  set {
    name = "config.SECURITY_JWT_PUBLIC_KEY"
    value = tls_private_key.jwt.public_key_pem
  }

  set {
    name = "config.JVB_MIN_POOL_SIZE"
    value = "1"
    type = "string"
  }

  set {
    name  = "ingress.hosts.main"
    value = var.jvbuster_host
  }
}

resource "time_sleep" "wait_jvbuster_load_balancer" {
  depends_on = [helm_release.jvbuster]

  create_duration = "5m"
}

data "kubernetes_ingress_v1" "jvbuster_ingress" {
  metadata {
    name = "jvbuster-connectclub-jvbuster"
  }
  depends_on = [time_sleep.wait_jvbuster_load_balancer]
}

resource "google_dns_record_set" "jvbuster" {
  provider     = google.dns
  name         = "${var.jvbuster_host}."
  managed_zone = data.google_dns_managed_zone.default.name
  type         = "A"
  ttl          = 300

  rrdatas = [data.kubernetes_ingress_v1.jvbuster_ingress.status.0.load_balancer.0.ingress.0.ip]
}
