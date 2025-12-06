resource "google_bigquery_dataset" "warehouse" {
  dataset_id                  = "dbt_prod"
  friendly_name               = "Production Data Warehouse"
  description                 = "Główny dataset tworzony przez Terraform"
  location                    = "US"
  default_table_expiration_ms = 3600000 * 24 * 30 
  delete_contents_on_destroy = true
  labels = {
    env = "production"
    managed_by = "terraform"
  }
}

resource "google_bigquery_table" "bitcoin_transactions" {
  dataset_id = google_bigquery_dataset.warehouse.dataset_id
  table_id   = "bitcoin_transactions"
  
  time_partitioning {
    type  = "DAY"
    field = "block_timestamp"
  }

  clustering = ["block_number", "hash"]

  schema = <<EOF
[
  {
    "name": "hash",
    "type": "STRING",
    "mode": "REQUIRED",
    "description": "Hash transakcji"
  },
  {
    "name": "size",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "virtual_size",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "version",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "lock_time",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "block_hash",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "block_number",
    "type": "INTEGER",
    "mode": "REQUIRED"
  },
  {
    "name": "block_timestamp",
    "type": "TIMESTAMP",
    "mode": "REQUIRED"
  },
  {
    "name": "input_count",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "output_count",
    "type": "INTEGER",
    "mode": "NULLABLE"
  },
  {
    "name": "input_value",
    "type": "NUMERIC",
    "mode": "NULLABLE"
  },
  {
    "name": "output_value",
    "type": "NUMERIC",
    "mode": "NULLABLE"
  },
  {
    "name": "fee",
    "type": "NUMERIC",
    "mode": "NULLABLE"
  }
]
EOF
}

resource "google_service_account" "dbt_runner" {
  account_id   = "dbt-runner-sa"
  display_name = "DBT Runner Service Account"
}