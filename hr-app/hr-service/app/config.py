import os

DB_HOST = os.getenv("DB_HOST", "localhost")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "hrdb")
DB_USER = os.getenv("DB_USER", "hr_app")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

KEYCLOAK_JWKS_URL = os.getenv("KEYCLOAK_JWKS_URL", "")

AWS_REGION = os.getenv("AWS_REGION", "ap-northeast-2")
DB_ACCESS_LOG_GROUP = os.getenv("DB_ACCESS_LOG_GROUP", "")
