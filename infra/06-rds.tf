
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.private_db[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "postgres_pg" {
  name   = "${local.name_prefix}-postgres-pg"
  family = "postgres15"

  parameter {
    name  = "log_min_duration_statement"
    value = "2000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "pgaudit.role"
    value        = "rds_pgaudit"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "pgaudit.log"
    value = "none"
  }

  parameter {
    name  = "pgaudit.log_parameter"
    value = "0"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

}

resource "aws_cloudwatch_log_data_protection_policy" "rds_postgresql_pii" {
  log_group_name = aws_cloudwatch_log_group.rds_postgresql.name

  policy_document = jsonencode({
    Name        = "HRDataMaskingPolicy"
    Description = "RDS 쿼리 로그에 남는 직원 이메일/이름을 자동 마스킹"
    Version     = "2021-06-01"
    Statement = [
      {
        Sid = "audit"
        DataIdentifier = [
          "arn:aws:dataprotection::aws:data-identifier/Name",
          "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
        ]
        Operation = {
          Audit = {
            FindingsDestination = {}
          }
        }
      },
      {
        Sid = "redact"
        DataIdentifier = [
          "arn:aws:dataprotection::aws:data-identifier/Name",
          "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
        ]
        Operation = {
          Deidentify = {
            MaskConfig = {}
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${local.name_prefix}-postgres-db/postgresql"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "rds_upgrade" {
  name              = "/aws/rds/instance/${local.name_prefix}-postgres-db/upgrade"
  retention_in_days = 7
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name_prefix}-postgres-db"
  engine         = "postgres"
  engine_version = "15.13"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  parameter_group_name = aws_db_parameter_group.postgres_pg.name

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  multi_az = var.multi_az_rds

  backup_retention_period = 7
  backup_window           = "16:00-16:30"
  copy_tags_to_snapshot   = true

  apply_immediately = true

  iam_database_authentication_enabled = true

  skip_final_snapshot = true

  depends_on = [
    aws_cloudwatch_log_group.rds_postgresql,
    aws_cloudwatch_log_group.rds_upgrade,
  ]

  tags = {
    Name = "${local.name_prefix}-postgres-db"
  }
}

resource "kubernetes_config_map" "hr_db_bootstrap_sql" {
  metadata {
    name      = "hr-db-bootstrap-sql"
    namespace = kubernetes_namespace.app_namespaces["hr-backend"].metadata[0].name
  }

  data = {
    "bootstrap.sql" = file("${path.module}/hr-data-masking-views.sql")
  }
}

resource "kubernetes_job" "hr_db_bootstrap" {
  metadata {

    name      = "hr-db-bootstrap-${substr(sha1("${aws_db_instance.main.resource_id}-${filesha1("${path.module}/hr-data-masking-views.sql")}"), 0, 16)}"
    namespace = kubernetes_namespace.app_namespaces["hr-backend"].metadata[0].name
  }

  spec {
    backoff_limit = 2

    template {
      metadata {
        annotations = {
          "sidecar.istio.io/inject" = "false"
        }
      }
      spec {
        restart_policy = "Never"

        container {
          name    = "psql"
          image   = "postgres:16.4-alpine"
          command = ["psql", "-v", "ON_ERROR_STOP=1", "-f", "/sql/bootstrap.sql"]

          env {
            name  = "PGHOST"
            value = aws_db_instance.main.address
          }
          env {
            name  = "PGPORT"
            value = tostring(aws_db_instance.main.port)
          }
          env {
            name  = "PGDATABASE"
            value = aws_db_instance.main.db_name
          }
          env {
            name  = "PGUSER"
            value = var.db_username
          }
          env {
            name  = "PGPASSWORD"
            value = var.db_password
          }

          volume_mount {
            name       = "sql"
            mount_path = "/sql"
          }
        }

        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map.hr_db_bootstrap_sql.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "3m"
  }

  depends_on = [
    aws_db_instance.main,
    kubernetes_config_map.hr_db_bootstrap_sql,
  ]
}
