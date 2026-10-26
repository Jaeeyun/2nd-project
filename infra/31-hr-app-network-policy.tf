
resource "kubernetes_network_policy" "hr_app_default_deny" {
  depends_on = [kubernetes_namespace.app_namespaces]

  metadata {
    name      = "default-deny-ingress"
    namespace = "hr-backend"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "hr_app_allow_from_alb" {
  depends_on = [kubernetes_namespace.app_namespaces]

  metadata {
    name      = "allow-ingress-from-alb-only"
    namespace = "hr-backend"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "hr-service"
      }
    }

    ingress {
      from {
        ip_block {
          cidr = var.vpc_cidr
        }
      }
      ports {
        port     = "8000"
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}
