resource "google_bigquery_dataset" "warehouse" {
  dataset_id                  = "dbt_prod"
  friendly_name               = "Production Data Warehouse"
  description                 = "Główny dataset tworzony przez Terraform"
  location                    = "US"
  default_table_expiration_ms = 3600000 * 24 * 30
  delete_contents_on_destroy  = true
  labels = {
    env        = "production"
    managed_by = "terraform"
  }
}

resource "google_bigquery_table" "bitcoin_transactions" {
  dataset_id          = google_bigquery_dataset.warehouse.dataset_id
  table_id            = "bitcoin_transactions"
  deletion_protection = false
  time_partitioning {
    type  = "DAY"
    field = "block_timestamp"
  }

  clustering = ["block_number", "hash"]

  schema = <<EOF
[
  { "name": "hash", "type": "STRING", "mode": "REQUIRED", "description": "Hash transakcji" },
  { "name": "size", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "virtual_size", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "version", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "lock_time", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "block_hash", "type": "STRING", "mode": "REQUIRED" },
  { "name": "block_number", "type": "INTEGER", "mode": "REQUIRED" },
  { "name": "block_timestamp", "type": "TIMESTAMP", "mode": "REQUIRED" },
  { "name": "input_count", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "output_count", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "input_value", "type": "NUMERIC", "mode": "NULLABLE" },
  { "name": "output_value", "type": "NUMERIC", "mode": "NULLABLE" },
  { "name": "fee", "type": "NUMERIC", "mode": "NULLABLE" }
]
EOF
}

resource "google_service_account" "dbt_runner" {
  account_id   = "dbt-runner-sa"
  display_name = "DBT Runner Service Account"
}

resource "google_project_service" "run_api" {
  project            = var.project_id
  service            = "run.googleapis.com"
  disable_on_destroy = false
}


resource "google_project_service" "secretmanager" {
  project = var.project_id
  service = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "grafana_sa" {
  account_id   = "grafana-dashboard-sa"
  display_name = "Grafana Service Account"
}

resource "google_project_iam_member" "grafana_bq_viewer" {
  project = var.project_id
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.grafana_sa.email}"
}

resource "google_project_iam_member" "grafana_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.grafana_sa.email}"
}


resource "google_secret_manager_secret" "grafana_dashboards_yaml" {
  secret_id = "grafana-provisioning-yaml"
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "grafana_dashboards_yaml_v1" {
  secret      = google_secret_manager_secret.grafana_dashboards_yaml.id
  secret_data = file("${path.module}/configs/dashboards.yaml")
}

resource "google_secret_manager_secret_iam_member" "grafana_secret_access" {
  for_each = toset([
    google_secret_manager_secret.grafana_dashboards_yaml.secret_id,
    google_secret_manager_secret.grafana_dashboard_json.secret_id
  ])
  
  project   = var.project_id # Upewnij się, że masz project_id, jeśli nie jest domyślny
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.grafana_sa.email}"
}

resource "google_secret_manager_secret" "grafana_dashboard_json" {
  secret_id = "grafana-dashboard-json"
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "grafana_dashboard_json_v1" {
  secret      = google_secret_manager_secret.grafana_dashboard_json.id
  secret_data = templatefile("${path.module}/configs/my_dashboard.json", {
    project_id = var.project_id
  })
}

resource "google_cloud_run_v2_service" "grafana" {
  name     = "grafana-dashboard"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  depends_on = [
    google_project_service.run_api,
    google_secret_manager_secret_version.grafana_dashboards_yaml_v1,
    google_secret_manager_secret_version.grafana_dashboard_json_v1,
    google_secret_manager_secret_iam_member.grafana_secret_access
  ]

  template {
    service_account = google_service_account.grafana_sa.email

    containers {
      image = "grafana/grafana:latest"
      
      ports {
        container_port = 3000
      }

      resources {
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
        cpu_idle = true
      }

      # ZWIĘKSZONY CZAS NA START (Instalacja pluginów trwa)
      startup_probe {
        initial_delay_seconds = 30 # Było 10, Grafana wstaje wolno z pluginami
        timeout_seconds       = 5
        period_seconds        = 10
        failure_threshold     = 10
        tcp_socket {
          port = 3000
        }
      }

      env {
        name  = "GF_INSTALL_PLUGINS"
        value = "grafana-bigquery-datasource"
      }
      env {
        name  = "GF_AUTH_ANONYMOUS_ENABLED"
        value = "true"
      }
      env {
        name  = "GF_AUTH_ANONYMOUS_ORG_ROLE"
        value = "Admin" 
      }
      env {
        name  = "GF_SERVER_HTTP_PORT"
        value = "3000"
      }
      # Ważne: Grafana w Cloud Run potrzebuje wiedzieć, że jest za proxy/load balancerem
      env {
        name  = "GF_SERVER_ROOT_URL"
        value = "%(protocol)s://%(domain)s/"
      }

      # --- POPRAWIONE MONTAŻE ---
      
      # 1. Montujemy do KATALOGU provisioning/dashboards.
      # Plik w środku będzie się nazywał tak, jak zdefiniowano w volumes (dashboards.yaml)
      volume_mounts {
        name       = "dashboards-yaml"
        mount_path = "/etc/grafana/provisioning/dashboards" 
        # Usunięto sub_path i nazwę pliku ze ścieżki
      }

      # 2. Montujemy do KATALOGU, gdzie Grafana ma szukać JSONów
      volume_mounts {
        name       = "dashboard-json"
        mount_path = "/etc/grafana-dashboards"
        # Usunięto sub_path i nazwę pliku ze ścieżki
      }
    }

    volumes {
      name = "dashboards-yaml"
      secret {
        secret = google_secret_manager_secret.grafana_dashboards_yaml.secret_id
        items {
          version = "latest"
          path    = "dashboards.yaml" # To ustala nazwę pliku wewnątrz folderu
        }
      }
    }
    volumes {
      name = "dashboard-json"
      secret {
        secret = google_secret_manager_secret.grafana_dashboard_json.secret_id
        items {
          version = "latest"
          path    = "my_dashboard.json" # To ustala nazwę pliku wewnątrz folderu
        }
      }
    }
  }
}

resource "google_cloud_run_service_iam_member" "public_access" {
  location = google_cloud_run_v2_service.grafana.location
  service  = google_cloud_run_v2_service.grafana.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "dashboard_url" {
  value = google_cloud_run_v2_service.grafana.uri
}