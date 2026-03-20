# L3: Nomad — Service Mesh with Consul Connect (mTLS Sidecar Proxy)
# Consul Connect provides service mesh capabilities via Envoy sidecar proxies.
# All traffic between services is encrypted with mTLS — no code changes required.
# Nomad + Consul integration: Nomad manages Envoy sidecars as native sidecar tasks.
#
# Prerequisites:
#   - Consul agent running on every Nomad client node
#   - Consul Connect enabled: connect { enabled = true } in Consul agent config
#   - Envoy binary available or CNI plugins for transparent proxy
#
# Apply: nomad job run service-mesh-webapp-consul-connect-sidecar.nomad.hcl

job "service-mesh-webapp" {
  datacenters = ["dc1"]
  type        = "service"

  group "webapp" {
    count = 2

    network {
      mode = "bridge"    # Required for Consul Connect — uses CNI bridge networking
      port "http" { to = 8080 }
    }

    # Consul Connect service registration with upstream dependencies
    service {
      name     = "webapp"
      port     = "8080"     # Port inside the bridge network
      provider = "consul"

      # Connect block enables the Envoy sidecar proxy
      connect {
        sidecar_service {
          # Upstream services this webapp needs to reach
          # Traffic to localhost:5432 is transparently proxied through Envoy to "postgres" service
          proxy {
            upstreams {
              destination_name = "postgres-db"
              local_bind_port  = 5432    # webapp connects to localhost:5432
            }
            upstreams {
              destination_name = "redis-cache"
              local_bind_port  = 6379    # webapp connects to localhost:6379
            }
          }
        }

        # Custom Envoy sidecar resource limits
        sidecar_task {
          resources {
            cpu    = 100
            memory = 128
          }
        }
      }

      # Consul health check (registered with Consul, not just Nomad)
      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
        expose   = true    # Expose health check via Envoy (needed in bridge mode)
      }
    }

    task "webapp" {
      driver = "docker"

      config {
        image = "myapp:1.2.3"
        ports = ["http"]
      }

      env {
        # App connects to upstream services via localhost (Envoy proxies to actual service)
        DB_HOST    = "127.0.0.1"
        DB_PORT    = "5432"
        REDIS_HOST = "127.0.0.1"
        REDIS_PORT = "6379"
        APP_PORT   = "8080"
      }

      resources {
        cpu    = 200
        memory = 256
      }
    }
  }

  # Postgres service group (Connect-enabled — accepts mTLS from authorized services only)
  group "postgres" {
    count = 1

    network {
      mode = "bridge"
      port "db" { to = 5432 }
    }

    service {
      name     = "postgres-db"
      port     = "5432"
      provider = "consul"

      connect {
        sidecar_service {}    # No upstreams needed — postgres doesn't call other services
      }

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "postgres:16-alpine"
        ports = ["db"]
      }

      env {
        POSTGRES_DB       = "appdb"
        POSTGRES_USER     = "appuser"
        POSTGRES_PASSWORD = "changeme"    # Use Vault template in production
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }
}
