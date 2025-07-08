import os
import psycopg2

db_params = {
    "user": os.environ["PG_USERNAME"],
    "password": os.environ["PG_PASSWORD"],
    "host": os.environ["PG_HOST_DESTINATION"],
    "port": os.environ.get("PG_PORT", "5432"),
    "dbname": os.environ["PG_DATABASE"],
    "sslmode": "require",
}  #!/usr/bin/env python3
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
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def get_db_connection():
    """
    Establish connection to PostgreSQL database using environment variables
    """
    db_params = {
        "user": os.getenv("PG_USERNAME"),
        "password": os.getenv("PG_PASSWORD"),
        "host": os.getenv("PG_HOST_DESTINATION"),
        "port": os.getenv("PG_PORT", "5432"),
        "dbname": os.getenv("PG_DATABASE"),
        "sslmode": "require",
    }

    # Validate required parameters
    required_params = ["user", "password", "host", "dbname"]
    missing_params = [param for param in required_params if not db_params.get(param)]

    if missing_params:
        raise ValueError(
            f"Missing required database parameters: {', '.join(missing_params)}"
        )

    logger.info(f"Connecting to PostgreSQL at {db_params['host']}:{db_params['port']}")
    logger.info(f"Database: {db_params['dbname']}, User: {db_params['user']}")

    return psycopg2.connect(**db_params)


def check_table_exists(cursor, table_name):
    """
    Check if target table exists in the database
    """
    cursor.execute(
        """
        SELECT EXISTS (
            SELECT FROM information_schema.tables
            WHERE table_name = %s
        );
    """,
        (table_name,),
    )

    return cursor.fetchone()[0]


def get_table_structure(cursor, table_name):
    """
    Get the structure of the target table
    """
    cursor.execute(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_name = %s
        ORDER BY ordinal_position;
    """,
        (table_name,),
    )

    return cursor.fetchall()


def validate_csv_file(csv_file_path):
    """
    Validate that the CSV file exists and is readable
    """
    if not Path(csv_file_path).exists():
        raise FileNotFoundError(f"CSV file not found: {csv_file_path}")

    if not Path(csv_file_path).is_file():
        raise ValueError(f"Path is not a file: {csv_file_path}")

    # Check if file is readable and get basic info
    try:
        with open(csv_file_path, "r", encoding="utf-8") as f:
            # Read first few lines to validate format
            csv_reader = csv.reader(f)
            header = next(csv_reader)
            sample_row = next(csv_reader, None)

            logger.info(f"CSV file validation passed")
            logger.info(f"Header columns: {header}")
            logger.info(f"Total columns: {len(header)}")

            return header, sample_row
    except Exception as e:
        raise ValueError(f"Error reading CSV file: {e}")


def clear_table(cursor, table_name):
    """
    Clear existing data from the table (optional)
    """
    cursor.execute(f"DELETE FROM {table_name}")
    deleted_rows = cursor.rowcount
    logger.info(f"Cleared {deleted_rows} existing rows from {table_name}")


def import_csv_data(csv_file_path, table_name, clear_existing=False):
    """
    Import CSV data into PostgreSQL table
    """
    try:
        # Validate CSV file
        header, sample_row = validate_csv_file(csv_file_path)

        # Connect to database
        with get_db_connection() as conn:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                # Check if table exists
                if not check_table_exists(cur, table_name):
                    raise ValueError(f"Target table '{table_name}' does not exist")

                # Get table structure
                table_structure = get_table_structure(cur, table_name)
                logger.info(
                    f"Target table '{table_name}' has {len(table_structure)} columns"
                )

                # Clear existing data if requested
                if clear_existing:
                    clear_table(cur, table_name)

                # Import data using COPY command (most efficient)
                logger.info(f"Starting data import from {csv_file_path}")

                with open(csv_file_path, "r", encoding="utf-8") as f:
                    # Skip header row
                    next(f)

                    # Use COPY command for efficient bulk insert
                    copy_sql = f"COPY {table_name} FROM STDIN WITH CSV"
                    cur.copy_expert(copy_sql, f)

                # Get row count
                cur.execute(f"SELECT COUNT(*) FROM {table_name}")
                total_rows = cur.fetchone()[0]

                conn.commit()
                logger.info(f"✅ Successfully imported data into '{table_name}'")
                logger.info(f"Total rows in table: {total_rows}")

                return total_rows

    except psycopg2.Error as e:
        logger.error(f"❌ PostgreSQL error: {e}")
        raise
    except Exception as e:
        logger.error(f"❌ Error during import: {e}")
        raise


def main():
    """
    Main function to run the data import
    """
    # Get parameters from environment or use defaults
    csv_file = os.getenv("CSV_FILE_PATH", "exported_data_vector_score.csv")
    target_table = os.getenv("TARGET_TABLE", "vector_store")
    clear_existing = os.getenv("CLEAR_EXISTING_DATA", "false").lower() == "true"

    logger.info("=== PostgreSQL Data Population Script ===")
    logger.info(f"CSV File: {csv_file}")
    logger.info(f"Target Table: {target_table}")
    logger.info(f"Clear Existing Data: {clear_existing}")

    try:
        # Import the data
        row_count = import_csv_data(csv_file, target_table, clear_existing)

        logger.info("=== Import Summary ===")
        logger.info(f"✅ Successfully imported {row_count} rows")
        logger.info(f"✅ Data population completed successfully")

        return 0

    except Exception as e:
        logger.error("=== Import Failed ===")
        logger.error(f"❌ {str(e)}")
        return 1


if __name__ == "__main__":
    sys.exit(main())

csv_file = "exported_data_vector_score.csv"
target_table = "vector_store"

try:
    with psycopg2.connect(**db_params) as conn:
        with conn.cursor() as cur:
            with open(csv_file, "r", encoding="utf-8") as f:
                next(f)  # skip header
                cur.copy_expert(f"COPY {target_table} FROM STDIN WITH CSV", f)
        conn.commit()
        print(f"✅ Imported data from '{csv_file}' into table '{target_table}'.")
except Exception as e:
    print(f"❌ Error during import: {e}")
