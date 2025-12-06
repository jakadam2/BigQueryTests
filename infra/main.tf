resource "google_bigquery_dataset" "warehouse" {
  dataset_id                  = "dbt_prod"
  friendly_name               = "Production Data Warehouse"
  description                 = "Główny dataset tworzony przez Terraform"
  location                    = "US"
  default_table_expiration_ms = 3600000 * 24 * 30 

  labels = {
    env = "production"
    managed_by = "terraform"
  }
}

resource "google_service_account" "dbt_runner" {
  account_id   = "dbt-runner-sa"
  display_name = "DBT Runner Service Account"
}