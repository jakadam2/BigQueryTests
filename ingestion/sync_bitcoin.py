import os
import time
from google.cloud import bigquery

PROJECT_ID = os.environ['GCP_PROJECT_ID']
DATASET_ID = "dbt_prod"
TARGET_TABLE = "bitcoin_transactions"
FULL_TARGET_ID = f"{PROJECT_ID}.{DATASET_ID}.{TARGET_TABLE}"
SOURCE_TABLE = "bigquery-public-data.crypto_bitcoin.transactions"

DEFAULT_START_DATE = '2024-01-01'

MANUAL_START_DATE = os.getenv('MANUAL_START_DATE')

def get_last_timestamp(client):
    """Fetches the latest block timestamp from the target table."""
    query = f"SELECT MAX(block_timestamp) as last_time FROM `{FULL_TARGET_ID}`"
    job = client.query(query)
    result = list(job.result())
    return result[0].last_time

def run_query(client, query):
    print("Running query in BigQuery...")
    
    start_time = time.time()
    
    job_config = bigquery.QueryJobConfig(
        priority=bigquery.QueryPriority.INTERACTIVE
    )
    
    query_job = client.query(query, job_config=job_config)
    result = query_job.result() 
    
    end_time = time.time()
    duration = end_time - start_time
    
    gb_processed = (query_job.total_bytes_processed or 0) / (1024**3)
    rows_inserted = query_job.num_dml_affected_rows or 0
    
    print("-" * 40)
    print(f"SUCCESS")
    print(f"Duration:      {duration:.2f} seconds")
    print(f"Data Scanned:  {gb_processed:.4f} GB (Cost metric)")
    print(f"Rows Inserted: {rows_inserted} rows")
    print("-" * 40)

def sync_data():
    client = bigquery.Client(project=PROJECT_ID)
    
    columns = "`hash`, `size`, `virtual_size`, `version`, `lock_time`, `block_hash`, `block_number`, `block_timestamp`, `input_count`, `output_count`, `input_value`, `output_value`, `fee`"

    if MANUAL_START_DATE:
        print(f"--- MODE: MANUAL FORCE LOAD ---")
        print(f"User provided start date: {MANUAL_START_DATE}")
        print("WARNING: This will load data regardless of duplicates!")

        query = f"""
            INSERT INTO `{FULL_TARGET_ID}` 
            ({columns})
            SELECT 
                {columns}
            FROM `{SOURCE_TABLE}`
            WHERE block_timestamp >= '{MANUAL_START_DATE}'
        """
        run_query(client, query)
        return

    last_ts = get_last_timestamp(client)

    if last_ts is None:
        print(f"--- MODE: INITIAL LOAD (BACKFILL) ---")
        print(f"Target table is empty. Fetching history starting from {DEFAULT_START_DATE}.")
        
        query = f"""
            INSERT INTO `{FULL_TARGET_ID}` 
            ({columns})
            SELECT 
                {columns}
            FROM `{SOURCE_TABLE}`
            WHERE block_timestamp >= '{DEFAULT_START_DATE}'
        """
        run_query(client, query)

    else:
        print(f"--- MODE: INCREMENTAL LOAD ---")
        print(f"Last transaction in DB: {last_ts}")
        print("Fetching only newer blocks...")

        query = f"""
            INSERT INTO `{FULL_TARGET_ID}` 
            ({columns})
            SELECT 
                {columns}
            FROM `{SOURCE_TABLE}`
            WHERE block_timestamp > TIMESTAMP('{last_ts}')
        """
        run_query(client, query)

if __name__ == "__main__":
    sync_data()