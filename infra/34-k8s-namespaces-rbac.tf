
resource "kubernetes_namespace" "app_namespaces" {
  for_each = toset(["frontend", "employee-backend", "hr-backend"])

  metadata {
    name = each.key
    labels = {

      "pod-security.kubernetes.io/audit"         = "baseline"
      "pod-security.kubernetes.io/audit-version" = "latest"
      "pod-security.kubernetes.io/warn"          = "baseline"

      "istio-injection" = "enabled"
    }
  }
}

resource "aws_eks_access_entry" "dev_general" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.standard["dev-general"].arn
  kubernetes_groups = ["dev-general"]
  user_name         = "user:{{SessionName}}"
  type              = "STANDARD"
}

resource "aws_eks_access_entry" "dev_lead" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.standard["dev-lead"].arn
  kubernetes_groups = ["dev-lead"]
  user_name         = "user:{{SessionName}}"
  type              = "STANDARD"
}

resource "aws_eks_access_entry" "dev_hr_backend" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.standard["dev-hr-backend"].arn
  kubernetes_groups = ["dev-hr-backend"]
  user_name         = "user:{{SessionName}}"
  type              = "STANDARD"
}

resource "aws_eks_access_entry" "security_auditor" {
  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = aws_iam_role.security_auditor.arn
  kubernetes_groups = ["security-auditor"]
  user_name         = "user:{{SessionName}}"
  type              = "STANDARD"
}

resource "kubernetes_cluster_role" "dev_view" {
  metadata {
    name = "dev-view"
  }

  rule {
    api_groups = ["", "apps", "batch"]
    resources  = ["pods", "pods/log", "deployments", "services", "configmaps", "jobs", "cronjobs", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role" "dev_edit" {
  metadata {
    name = "dev-edit"
  }

  rule {
    api_groups = ["", "apps", "batch"]
    resources  = ["pods", "pods/log", "deployments", "services", "configmaps", "jobs", "cronjobs", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "dev_view_open_namespaces" {
  for_each = toset(["frontend", "employee-backend"])

  metadata {
    name      = "dev-general-view"
    namespace = kubernetes_namespace.app_namespaces[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dev_view.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "dev-general"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_role_binding" "dev_edit_open_namespaces" {
  for_each = toset(["frontend", "employee-backend"])

  metadata {
    name      = "dev-lead-edit"
    namespace = kubernetes_namespace.app_namespaces[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dev_edit.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "dev-lead"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_role_binding" "hr_backend_access" {
  metadata {
    name      = "dev-hr-backend-edit"
    namespace = kubernetes_namespace.app_namespaces["hr-backend"].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dev_edit.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "dev-hr-backend"
    api_group = "rbac.authorization.k8s.io"
  }
}

resource "kubernetes_cluster_role_binding" "security_auditor_view" {
  metadata {
    name = "security-auditor-view"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dev_view.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "security-auditor"
    api_group = "rbac.authorization.k8s.io"
  }
}
