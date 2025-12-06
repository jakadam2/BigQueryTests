import os
from google.cloud import bigquery

PROJECT_ID = os.environ['GCP_PROJECT_ID']
DATASET_ID = "dbt_prod"
TARGET_TABLE = "bitcoin_transactions"
FULL_TARGET_ID = f"{PROJECT_ID}.{DATASET_ID}.{TARGET_TABLE}"
SOURCE_TABLE = "bigquery-public-data.crypto_bitcoin.transactions"

def get_last_timestamp(client):
    """Sprawdza datę ostatniej transakcji w NASZEJ tabeli"""
    query = f"SELECT MAX(block_timestamp) as last_time FROM `{FULL_TARGET_ID}`"
    try:
        job = client.query(query)
        result = list(job.result())
        return result[0].last_time
    except Exception as e:
        print(f"Tabela prawdopodobnie pusta lub błąd: {e}")
        return None

def run_query(client, query):
    print("Uruchamiam zapytanie w BigQuery...")
    job_config = bigquery.QueryJobConfig(
        priority=bigquery.QueryPriority.INTERACTIVE
    )
    query_job = client.query(query, job_config=job_config)
    result = query_job.result()
    print(f"Sukces! Przetworzono danych (skan): {query_job.total_bytes_processed / 1024**3:.4f} GB")

def sync_data():
    client = bigquery.Client(project=PROJECT_ID)
    
    last_ts = get_last_timestamp(client)

    columns = "`hash`, `size`, `virtual_size`, `version`, `lock_time`, `block_hash`, `block_number`, `block_timestamp`, `input_count`, `output_count`, `input_value`, `output_value`, `fee`"

    if last_ts is None:
        print("--- TRYB: INITIAL LOAD (BACKFILL) ---")
        print("Tabela docelowa jest pusta. Pobieram historię od 2024-01-01.")
        
        query = f"""
            INSERT INTO `{FULL_TARGET_ID}` 
            ({columns})
            SELECT 
                {columns}
            FROM `{SOURCE_TABLE}`
            WHERE block_timestamp >= '2024-01-01'
        """
        run_query(client, query)
        print("Initial Load zakończony.")

    else:
        print(f"--- TRYB: INCREMENTAL LOAD ---")
        print(f"Ostatnia transakcja w bazie: {last_ts}")
        print("Pobieram tylko nowsze bloki...")

        query = f"""
            INSERT INTO `{FULL_TARGET_ID}` 
            ({columns})
            SELECT 
                {columns}
            FROM `{SOURCE_TABLE}`
            WHERE block_timestamp > TIMESTAMP('{last_ts}')
        """
        run_query(client, query)
        print("Incremental Load zakończony.")

if __name__ == "__main__":
    sync_data()