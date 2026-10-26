
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'rds_pgaudit') THEN
    CREATE ROLE rds_pgaudit NOLOGIN;
  END IF;
END
$$;
CREATE EXTENSION IF NOT EXISTS pgaudit;

GRANT SELECT, INSERT, UPDATE, DELETE ON employees TO rds_pgaudit;
GRANT SELECT, INSERT, UPDATE, DELETE ON change_history TO rds_pgaudit;

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'general_user_readonly') THEN
    CREATE ROLE general_user_readonly LOGIN;
    GRANT rds_iam TO general_user_readonly;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'approver_readonly') THEN
    CREATE ROLE approver_readonly LOGIN;
    GRANT rds_iam TO approver_readonly;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'security_auditor_readonly') THEN
    CREATE ROLE security_auditor_readonly LOGIN;
    GRANT rds_iam TO security_auditor_readonly;
  END IF;

  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'db_admin') THEN
    CREATE ROLE db_admin LOGIN;
    GRANT rds_iam TO db_admin;

  END IF;

  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'remediation_admin') THEN
    CREATE ROLE remediation_admin LOGIN;
    GRANT rds_iam TO remediation_admin;

  END IF;
END
$$;

GRANT adminuser TO remediation_admin;
GRANT adminuser TO db_admin;

CREATE SCHEMA IF NOT EXISTS masked;

CREATE OR REPLACE VIEW masked.employees_general AS
SELECT
  id,
  email,
  name,
  department,
  position,
  is_hr,
  NULL::integer AS salary
FROM employees;

CREATE OR REPLACE VIEW masked.employees_audit AS
SELECT
  id,
  email,
  name,
  department,
  position,
  is_hr,
  salary
FROM employees;

CREATE OR REPLACE VIEW masked.change_history_general AS
SELECT
  id,
  employee_id,
  field_name,
  CASE WHEN field_name = 'salary' THEN '****' ELSE old_value END AS old_value,
  CASE WHEN field_name = 'salary' THEN '****' ELSE new_value END AS new_value,
  changed_by,
  department,
  reason,
  changed_at
FROM change_history;

CREATE OR REPLACE VIEW masked.change_history_audit AS
SELECT
  id,
  employee_id,
  field_name,
  old_value,
  new_value,
  changed_by,
  department,
  reason,
  changed_at
FROM change_history;

REVOKE ALL ON employees FROM PUBLIC;
REVOKE ALL ON change_history FROM PUBLIC;
REVOKE ALL ON employees, change_history FROM general_user_readonly, approver_readonly, security_auditor_readonly;

GRANT USAGE ON SCHEMA masked TO general_user_readonly, approver_readonly, security_auditor_readonly;

GRANT SELECT ON masked.employees_general, masked.change_history_general TO general_user_readonly, approver_readonly;
GRANT SELECT ON masked.employees_audit, masked.change_history_audit TO security_auditor_readonly;
