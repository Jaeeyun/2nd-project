
locals {
  istio_chart_version = "1.23.2"
  istio_repo          = "https://istio-release.storage.googleapis.com/charts"
}

resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
  }
}

resource "kubernetes_namespace" "oauth2_proxy" {
  metadata {
    name = "oauth2-proxy"
  }
}

resource "kubernetes_namespace" "opa" {
  metadata {
    name = "opa"
  }
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = local.istio_repo
  chart      = "base"
  version    = local.istio_chart_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = local.istio_repo
  chart      = "istiod"
  version    = local.istio_chart_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  values = [
    yamlencode({

      pilot = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
        }
      }
      meshConfig = {
        accessLogFile = "/dev/stdout"
        defaultConfig = {
          gatewayTopology = {
            numTrustedProxies = 1
          }
        }
        extensionProviders = [
          {
            name = "oauth2-proxy"
            envoyExtAuthzHttp = {
              service                      = "oauth2-proxy.oauth2-proxy.svc.cluster.local"
              port                         = 4180
              includeRequestHeadersInCheck = ["cookie", "authorization", "x-forwarded-proto", "x-forwarded-host", "x-forwarded-uri"]

              headersToUpstreamOnAllow  = ["authorization", "x-auth-request-access-token", "x-auth-request-preferred-username", "x-auth-request-email"]
              headersToDownstreamOnDeny = ["set-cookie", "location", "content-type", "content-length"]
              includeAdditionalHeadersInCheck = {
                "x-forwarded-method" = "%REQ(:METHOD)%"
              }
            }
          },
          {
            name = "opa-envoy"
            envoyExtAuthzGrpc = {
              service = "opa-envoy.opa.svc.cluster.local"
              port    = 9191
            }
          },
        ]
      }
    })
  ]

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingressgateway" {
  name       = "istio-ingressgateway"
  repository = local.istio_repo
  chart      = "gateway"
  version    = local.istio_chart_version
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  values = [
    yamlencode({
      service = {
        type = "ClusterIP"
        ports = [
          { name = "http2", port = 8080, targetPort = 8080, protocol = "TCP" },
          { name = "status-port", port = 15021, targetPort = 15021, protocol = "TCP" },
        ]
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
      }
    })
  ]

  depends_on = [helm_release.istiod]
}

resource "kubernetes_config_map" "opa_policy" {
  metadata {
    name      = "opa-policy"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }

  data = {
    "policy.rego" = <<-REGO
      package envoy.authz

      import future.keywords.if
      import future.keywords.in

      default allow := false

      allow if {
      	device_currently_trusted
      	host_allowed
      }

      access_token := t if {
      	t := input.attributes.request.http.headers["x-auth-request-access-token"]
      }

      jwks := resp.raw_body if {
      	resp := http.send({
      		"method": "GET",
      		"url": "https://${aws_lb.keycloak.dns_name}/realms/${var.keycloak_realm_name}/protocol/openid-connect/certs",
      		"tls_ca_cert_file": "/etc/keycloak-ca/ca.pem",
      		"force_cache": true,
      		"force_cache_duration_seconds": 300,
      	})
      }

      claims := payload if {
      	result := io.jwt.decode_verify(access_token, {"cert": jwks, "alg": "RS256", "aud": "hr-app"})
      	result[0] == true
      	payload := result[2]
      }

      device_currently_trusted if {
      	resp := http.send({
      		"method": "GET",
      		"url": sprintf("%s?device_cn=%s", [opa.runtime().env.DEVICE_POSTURE_LOOKUP_URL, claims.preferred_username]),
      		"headers": {"x-api-key": opa.runtime().env.DEVICE_POSTURE_LOOKUP_API_KEY},
      		"force_cache": false,
      		"timeout": "2s",
      	})
      	resp.status_code == 200
      	resp.body.trusted == true
      }

      authority := input.attributes.request.http.headers[":authority"]

      host_allowed if {
      	not startswith(authority, "hr.company.com")
      }

      host_allowed if {
      	startswith(authority, "hr.company.com")
      	"hr-group" in claims.groups
      }
    REGO

    "log_mask.rego" = <<-REGO
      package system.log

      mask[x] {
      	x := "/input/attributes/request/http/headers/x-auth-request-access-token"
      }

      mask[x] {
      	x := "/input/attributes/request/http/headers/authorization"
      }

      mask[x] {
      	x := "/input/attributes/request/http/headers/cookie"
      }
    REGO
  }
}

resource "kubernetes_config_map" "keycloak_ca_opa" {
  metadata {
    name      = "keycloak-ca"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }
  data = {
    "ca.pem" = tls_self_signed_cert.keycloak_alb_ca.cert_pem
  }
}

resource "kubernetes_secret" "device_posture_lookup" {
  metadata {
    name      = "device-posture-lookup"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }
  data = {
    url     = "${aws_api_gateway_stage.device_posture_lookup.invoke_url}/posture"
    api_key = random_password.device_posture_lookup_api_key.result
  }
}

resource "kubernetes_deployment" "opa_envoy" {
  metadata {
    name      = "opa-envoy"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "opa-envoy" }
    }
    template {
      metadata {
        labels = { app = "opa-envoy" }
      }
      spec {
        container {
          name  = "opa"
          image = "openpolicyagent/opa:0.70.0-envoy"
          args = [
            "run",
            "--server",
            "--addr=0.0.0.0:8181",
            "--diagnostic-addr=0.0.0.0:8282",
            "--set=plugins.envoy_ext_authz_grpc.addr=0.0.0.0:9191",
            "--set=plugins.envoy_ext_authz_grpc.query=data.envoy.authz.allow",

            "--set=decision_logs.console=true",

            "/policies/policy.rego",
            "/policies/log_mask.rego",
          ]
          env {
            name = "DEVICE_POSTURE_LOOKUP_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.device_posture_lookup.metadata[0].name
                key  = "url"
              }
            }
          }
          env {
            name = "DEVICE_POSTURE_LOOKUP_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.device_posture_lookup.metadata[0].name
                key  = "api_key"
              }
            }
          }
          port {
            container_port = 9191
            name           = "grpc"
          }
          port {
            container_port = 8181
            name           = "http"
          }
          volume_mount {
            name       = "policy"
            mount_path = "/policies"
          }
          volume_mount {
            name       = "keycloak-ca"
            mount_path = "/etc/keycloak-ca"
            read_only  = true
          }
        }
        volume {
          name = "policy"
          config_map {
            name = kubernetes_config_map.opa_policy.metadata[0].name
          }
        }
        volume {
          name = "keycloak-ca"
          config_map {
            name = kubernetes_config_map.keycloak_ca_opa.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "opa_envoy" {
  metadata {
    name      = "opa-envoy"
    namespace = kubernetes_namespace.opa.metadata[0].name
  }
  spec {
    selector = { app = "opa-envoy" }
    port {
      name        = "grpc"
      port        = 9191
      target_port = 9191
    }
    port {
      name        = "http"
      port        = 8181
      target_port = 8181
    }
  }
}

resource "random_id" "oauth2_proxy_cookie_secret" {
  byte_length = 32
}

resource "kubernetes_config_map" "keycloak_ca" {
  metadata {
    name      = "keycloak-ca"
    namespace = kubernetes_namespace.oauth2_proxy.metadata[0].name
  }
  data = {
    "ca.pem" = tls_self_signed_cert.keycloak_alb_ca.cert_pem
  }
}

resource "kubernetes_deployment" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace.oauth2_proxy.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "oauth2-proxy" }
    }
    template {
      metadata {
        labels = { app = "oauth2-proxy" }
      }
      spec {
        container {
          name  = "oauth2-proxy"
          image = "quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"
          args = [
            "--http-address=0.0.0.0:4180",
            "--provider=keycloak-oidc",
            "--oidc-issuer-url=https://${aws_lb.keycloak.dns_name}/realms/${var.keycloak_realm_name}",

            "--client-id=hr-app",
            "--client-secret=${random_password.webapp_oidc_client_secret.result}",

            "--cookie-secret=${random_id.oauth2_proxy_cookie_secret.b64_url}",
            "--cookie-secure=true",
            "--email-domain=*",
            "--skip-provider-button=true",
            "--pass-access-token=true",
            "--pass-authorization-header=true",
            "--set-xauthrequest=true",
            "--reverse-proxy=true",
            "--whitelist-domain=employee.company.com",
            "--whitelist-domain=hr.company.com",
            "--upstream=static://200",
            "--insecure-oidc-skip-issuer-verification=true",

            "--provider-ca-file=/etc/keycloak-ca/ca.pem",

            "--session-store-type=redis",
            "--redis-connection-url=redis://redis.${kubernetes_namespace.oauth2_proxy.metadata[0].name}.svc.cluster.local:6379",
          ]
          volume_mount {
            name       = "keycloak-ca"
            mount_path = "/etc/keycloak-ca"
            read_only  = true
          }
          port {
            container_port = 4180
          }
        }
        volume {
          name = "keycloak-ca"
          config_map {
            name = kubernetes_config_map.keycloak_ca.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "oauth2_proxy" {
  metadata {
    name      = "oauth2-proxy"
    namespace = kubernetes_namespace.oauth2_proxy.metadata[0].name
  }
  spec {
    selector = { app = "oauth2-proxy" }
    port {
      port        = 4180
      target_port = 4180
    }
  }
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.oauth2_proxy.metadata[0].name
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "redis" }
    }
    template {
      metadata {
        labels = { app = "redis" }
      }
      spec {
        container {
          name  = "redis"
          image = "redis:7.4.1-alpine"
          port {
            container_port = 6379
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.oauth2_proxy.metadata[0].name
  }
  spec {
    selector = { app = "redis" }
    port {
      port        = 6379
      target_port = 6379
    }
  }
}

resource "null_resource" "istio_routing_apply" {
  depends_on = [
    helm_release.istio_ingressgateway,
    kubernetes_service.oauth2_proxy,
    kubernetes_service.opa_envoy,
    kubernetes_namespace.app_namespaces,
  ]

  triggers = {
    cluster_name = aws_eks_cluster.main.name
    manifest_hash = md5(<<-YAML
      apiVersion: networking.istio.io/v1
      kind: Gateway
      metadata:
        name: ztna-gateway
        namespace: istio-system
      spec:
        selector:
          istio: ingressgateway
        servers:
        - port:
            number: 8080
            name: http
            protocol: HTTP
          hosts:
          - "employee.company.com"
          - "hr.company.com"
      ---
      apiVersion: security.istio.io/v1
      kind: PeerAuthentication
      metadata:
        name: default
        namespace: istio-system
      spec:
        mtls:
          mode: STRICT
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step1-oauth2-proxy
        namespace: istio-system
      spec:
        selector:
          matchLabels: {istio: ingressgateway}
        action: CUSTOM
        provider:
          name: oauth2-proxy
        rules:
        - to:
          - operation:
              notPaths: ["/oauth2/*"]
      ---
      apiVersion: networking.istio.io/v1
      kind: VirtualService
      metadata:
        name: employee-routes
        namespace: istio-system
      spec:
        hosts:
        - "employee.company.com"
        gateways:
        - ztna-gateway
        http:
        - match:
          - uri: {prefix: /oauth2/}
          route:
          - destination:
              host: oauth2-proxy.oauth2-proxy.svc.cluster.local
              port: {number: 4180}
        - match:
          - uri: {prefix: /api/employee}
          route:
          - destination:
              host: employee-service.employee-backend.svc.cluster.local
              port: {number: 8000}
        - route:
          - destination:
              host: frontend.frontend.svc.cluster.local
              port: {number: 80}
      ---
      apiVersion: networking.istio.io/v1
      kind: VirtualService
      metadata:
        name: hr-routes
        namespace: istio-system
      spec:
        hosts:
        - "hr.company.com"
        gateways:
        - ztna-gateway
        http:
        - match:
          - uri: {prefix: /oauth2/}
          route:
          - destination:
              host: oauth2-proxy.oauth2-proxy.svc.cluster.local
              port: {number: 4180}
        - match:
          - uri: {prefix: /api/hr}
          route:
          - destination:
              host: hr-service.hr-backend.svc.cluster.local
              port: {number: 8000}
        - route:
          - destination:
              host: frontend.frontend.svc.cluster.local
              port: {number: 80}
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step2-opa-device-check
        namespace: employee-backend
      spec:
        action: CUSTOM
        provider:
          name: opa-envoy
        rules:
        - {}
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step2-opa-device-check
        namespace: hr-backend
      spec:
        action: CUSTOM
        provider:
          name: opa-envoy
        rules:
        - {}
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step2-opa-device-check
        namespace: frontend
      spec:
        action: CUSTOM
        provider:
          name: opa-envoy
        rules:
        - {}
    YAML
    )
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${var.aws_region} --kubeconfig /tmp/ztna-poc-kubeconfig
      export KUBECONFIG=/tmp/ztna-poc-kubeconfig
      cat <<'YAML' | kubectl apply -f -
      apiVersion: networking.istio.io/v1
      kind: Gateway
      metadata:
        name: ztna-gateway
        namespace: istio-system
      spec:
        selector:
          istio: ingressgateway
        servers:
        - port:
            number: 8080
            name: http
            protocol: HTTP
          hosts:
          - "employee.company.com"
          - "hr.company.com"
      ---
      apiVersion: security.istio.io/v1
      kind: PeerAuthentication
      metadata:
        name: default
        namespace: istio-system
      spec:
        mtls:
          mode: STRICT
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step1-oauth2-proxy
        namespace: istio-system
      spec:
        selector:
          matchLabels: {istio: ingressgateway}
        action: CUSTOM
        provider:
          name: oauth2-proxy
        rules:
        - to:
          - operation:
              notPaths: ["/oauth2/*"]
      ---
      apiVersion: networking.istio.io/v1
      kind: VirtualService
      metadata:
        name: employee-routes
        namespace: istio-system
      spec:
        hosts:
        - "employee.company.com"
        gateways:
        - ztna-gateway
        http:
        - match:
          - uri: {prefix: /oauth2/}
          route:
          - destination:
              host: oauth2-proxy.oauth2-proxy.svc.cluster.local
              port: {number: 4180}
        - match:
          - uri: {prefix: /api/employee}
          route:
          - destination:
              host: employee-service.employee-backend.svc.cluster.local
              port: {number: 8000}
        - route:
          - destination:
              host: frontend.frontend.svc.cluster.local
              port: {number: 80}
      ---
      apiVersion: networking.istio.io/v1
      kind: VirtualService
      metadata:
        name: hr-routes
        namespace: istio-system
      spec:
        hosts:
        - "hr.company.com"
        gateways:
        - ztna-gateway
        http:
        - match:
          - uri: {prefix: /oauth2/}
          route:
          - destination:
              host: oauth2-proxy.oauth2-proxy.svc.cluster.local
              port: {number: 4180}
        - match:
          - uri: {prefix: /api/hr}
          route:
          - destination:
              host: hr-service.hr-backend.svc.cluster.local
              port: {number: 8000}
        - route:
          - destination:
              host: frontend.frontend.svc.cluster.local
              port: {number: 80}
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step2-opa-device-check
        namespace: employee-backend
      spec:
        action: CUSTOM
        provider:
          name: opa-envoy
        rules:
        - {}
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step2-opa-device-check
        namespace: hr-backend
      spec:
        action: CUSTOM
        provider:
          name: opa-envoy
        rules:
        - {}
      ---
      apiVersion: security.istio.io/v1
      kind: AuthorizationPolicy
      metadata:
        name: step2-opa-device-check
        namespace: frontend
      spec:
        action: CUSTOM
        provider:
          name: opa-envoy
        rules:
        - {}
      YAML
    EOT
  }
}

output "istio_ingressgateway_service" {
  value = "istio-ingressgateway.istio-system.svc.cluster.local"
}
