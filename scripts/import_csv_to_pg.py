#!/usr/bin/env python3
"""
PostgreSQL Data Population Script
Imports CSV data into PostgreSQL database for CI/CD pipeline
"""

import os
import sys
import psycopg2
from psycopg2.extras import RealDictCursor
import csv
import logging
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def get_db_connection():
    db_params = {
        "user": "admintest",
        "password": "Initial_0524",
        "host": os.getenv("PG_HOST_DESTINATION", "localhost"),
        "port": "5432",
        "dbname": "postgres",
        "sslmode": "require"
    }

    if not db_params["host"] or db_params["host"] == "localhost":
        raise ValueError("PG_HOST_DESTINATION environment variable must be set")

    logger.info(f"Connecting to PostgreSQL at {db_params['host']}:{db_params['port']}")
    logger.info(f"Database: {db_params['dbname']}, User: {db_params['user']}")

    return psycopg2.connect(**db_params)

def find_csv_file(base_filename):
    possible_paths = [
        base_filename,
        f"scripts/{base_filename}",
        f"./{base_filename}",
        f"../scripts/{base_filename}",
    ]
    for path in possible_paths:
        if Path(path).exists():
            logger.info(f"Found CSV file at: {path}")
            return path

    logger.error(f"CSV file '{base_filename}' not found in any expected locations.")
    for path in possible_paths:
        logger.error(f"  - {path}")
    return None

def check_table_exists(cursor, table_name):
    cursor.execute("""
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_name = %s
        );
    """, (table_name,))
    return cursor.fetchone()[0]

def create_table_if_not_exists(cursor, table_name):
    cursor.execute(f"""
        CREATE TABLE IF NOT EXISTS {table_name} (
            id TEXT,
            title TEXT,
            chunk TEXT,
            chunk_id TEXT,
            offset TEXT,
            page_number TEXT,
            content TEXT,
            source TEXT,
            metadata TEXT,
            content_vector TEXT
        );
    """)
    logger.info(f"✅ Table '{table_name}' created or already exists.")

def validate_csv_file(csv_file_path):
    if not Path(csv_file_path).exists():
        raise FileNotFoundError(f"CSV file not found: {csv_file_path}")
    if not Path(csv_file_path).is_file():
        raise ValueError(f"Path is not a file: {csv_file_path}")
    with open(csv_file_path, 'r', encoding='utf-8') as f:
        csv_reader = csv.reader(f)
        header = next(csv_reader)
        sample_row = next(csv_reader, None)
        logger.info(f"CSV file validation passed")
        logger.info(f"Header columns: {header}")
        logger.info(f"Total columns: {len(header)}")
        return header, sample_row

def clear_table(cursor, table_name):
    cursor.execute(f"DELETE FROM {table_name}")
    logger.info(f"Cleared {cursor.rowcount} existing rows from {table_name}")

def import_csv_data(csv_file_path, table_name, clear_existing=False):
    try:
        header, sample_row = validate_csv_file(csv_file_path)
        with get_db_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                if not check_table_exists(cur, table_name):
                    logger.warning(f"Table '{table_name}' does not exist. Creating it.")
                    create_table_if_not_exists(cur, table_name)

                if clear_existing:
                    clear_table(cur, table_name)

                logger.info(f"Starting data import from {csv_file_path}")
                with open(csv_file_path, 'r', encoding='utf-8') as f:
                    next(f)
                    cur.copy_expert(f"COPY {table_name} FROM STDIN WITH CSV", f)

                cur.execute(f"SELECT COUNT(*) FROM {table_name}")
                total_rows = cur.fetchone()['count']
                conn.commit()
                logger.info(f"✅ Successfully imported data into '{table_name}'")
                logger.info(f"Total rows in table: {total_rows}")
                return total_rows
    except Exception as e:
        logger.error(f"❌ Error during import: {e}")
        raise

def main():
    csv_filename = os.getenv("CSV_FILE_PATH", "exported_data_vector_score.csv")
    target_table = os.getenv("TARGET_TABLE", "vector_store")
    clear_existing = os.getenv("CLEAR_EXISTING_DATA", "false").lower() == "true"

    logger.info("=== PostgreSQL Data Population Script ===")
    logger.info(f"CSV Filename: {csv_filename}")
    logger.info(f"Target Table: {target_table}")
    logger.info(f"Clear Existing Data: {clear_existing}")
    logger.info("Using hardcoded PostgreSQL credentials")

    try:
        csv_file_path = find_csv_file(csv_filename)
        if not csv_file_path:
            return 1
        row_count = import_csv_data(csv_file_path, target_table, clear_existing)
        logger.info(f"✅ Successfully imported {row_count} rows")
        return 0
    except Exception as e:
        logger.error("=== Import Failed ===")
        logger.error(f"❌ {str(e)}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
