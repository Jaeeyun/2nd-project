
import json
import os
import psycopg2
import boto3

rds = boto3.client("rds")

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ.get("DB_USER", "remediation_admin")
REGION = os.environ["AWS_REGION"]

WATCHED_TABLES = ["employees", "change_history"]
READONLY_ROLES = ["general_user_readonly", "approver_readonly"]

def _get_auth_token() -> str:
    return rds.generate_db_auth_token(
        DBHostname=DB_HOST, Port=DB_PORT, DBUsername=DB_USER, Region=REGION
    )

def handler(event, context):
    token = _get_auth_token()
    conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
        password=token, sslmode="require",
    )
    conn.autocommit = True
    drift_found = []

    try:
        with conn.cursor() as cur:
            for table in WATCHED_TABLES:

                cur.execute(
                    """
                    SELECT grantee, privilege_type
                    FROM information_schema.role_table_grants
                    WHERE table_name = %s AND grantee IN %s
                    """,
                    (table, tuple(READONLY_ROLES)),
                )
                rows = cur.fetchall()
                for grantee, privilege in rows:
                    drift_found.append((table, grantee, privilege))
                    cur.execute(f"REVOKE ALL ON {table} FROM {grantee};")

        for table, grantee, privilege in drift_found:
            print(json.dumps({
                "event": "RDS_PERMISSION_DRIFT_REVOKED",
                "table": table,
                "grantee": grantee,
                "privilege": privilege,
            }))
        return {"statusCode": 200, "drift_count": len(drift_found)}
    finally:
        conn.close()
