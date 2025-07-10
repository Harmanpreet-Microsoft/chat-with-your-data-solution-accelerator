import os
import psycopg2
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# DB connection parameters
db_params = {
    "user": os.getenv("PG_USERNAME"),
    "password": os.getenv("PG_PASSWORD"),
    "host": os.getenv("PG_HOST_DESTINATION"),
    "port": os.getenv("PG_PORT"),
    "dbname": os.getenv("PG_DATABASE"),
    "sslmode": "require"
}

csv_file = "exported_data_vector_score.csv"
target_table = "vector_store"

# Connect and import CSV
try:
    with psycopg2.connect(**db_params) as conn:
        with conn.cursor() as cur:
            with open(csv_file, "r", encoding="utf-8") as f:
                next(f)  # Skip the header row
                cur.copy_expert(f"COPY {target_table} FROM STDIN WITH CSV", f)

            conn.commit()
            print(f"✅ Imported data from '{csv_file}' into table '{target_table}'.")

except Exception as e:
    print(f"❌ Error during import : {e}")
