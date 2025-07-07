import os
import psycopg2

db_params = {
    "user": os.environ["PG_USERNAME"],
    "password": os.environ["PG_PASSWORD"],
    "host": os.environ["PG_HOST_DESTINATION"],
    "port": os.environ.get("PG_PORT", "5432"),
    "dbname": os.environ["PG_DATABASE"],
    "sslmode": "require"
}

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
