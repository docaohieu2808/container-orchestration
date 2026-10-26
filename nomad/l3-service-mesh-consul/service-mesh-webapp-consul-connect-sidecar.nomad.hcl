# L3: Nomad — Service Mesh with Consul Connect (mTLS Sidecar Proxy)
# Consul Connect provides service mesh capabilities via Envoy sidecar proxies.
# Traffic between services is encrypted with mTLS — no code changes required.
# Nomad + Consul integration: Nomad manages Envoy sidecars as native sidecar tasks.
#
# This job needs a real Nomad + Consul cluster, so CI validates it (`nomad job validate`) but does not
# run it. `myapp:1.2.3` is a placeholder for your own image. Prerequisites on every Nomad client:
#   - A Consul agent reachable by Nomad, with Connect enabled (`connect { enabled = true }` on the
#     Consul servers) and Nomad's `consul` block configured (Nomad 1.10+/2.x authenticates to Consul
#     with workload identity: a Consul JWT auth method trusting Nomad)
#   - CNI reference plugins installed (/opt/cni/bin) and the bridge/iptables kernel modules:
#     required by `network { mode = "bridge" }`
#   - Docker, to pull and run the Envoy sidecar image
# The Postgres password is read from a Nomad variable, create it first:
#   nomad var put nomad/jobs/service-mesh-webapp postgres_password="$(openssl rand -hex 16)"
#
# Apply: nomad job run service-mesh-webapp-consul-connect-sidecar.nomad.hcl

job "service-mesh-webapp" {
  datacenters = ["dc1"]
  type        = "service"

  group "webapp" {
    count = 2

    network {
      mode = "bridge" # Required for Consul Connect — uses CNI bridge networking
      port "http" { to = 8080 }
    }

    # Consul Connect service registration with upstream dependencies
    service {
      name     = "webapp"
      port     = "8080" # Port inside the bridge network
      provider = "consul"

      # Connect block enables the Envoy sidecar proxy
      connect {
        sidecar_service {
          # Upstream services this webapp needs to reach. Each upstream opens a local listener
          # (local_bind_port) on 127.0.0.1 inside the group's network namespace; Envoy forwards the
          # connection over mTLS to the destination service. (This is explicit upstream proxying,
          # not Consul's transparent proxy mode.)
          proxy {
            upstreams {
              destination_name = "postgres-db"
              local_bind_port  = 5432 # webapp connects to localhost:5432
            }
            upstreams {
              destination_name = "redis-cache"
              local_bind_port  = 6379 # webapp connects to localhost:6379
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
        expose   = true # Expose health check via Envoy (needed in bridge mode)
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
        sidecar_service {} # No upstreams needed — postgres doesn't call other services
      }
      # No Nomad check here: tcp checks are not valid on Connect-enabled services. Consul checks the
      # sidecar proxy itself, and the webapp's /health check (with expose = true) covers the app path.
    }

    task "postgres" {
      driver = "docker"

      config {
        image = "postgres:18-alpine"
        ports = ["db"]
      }

      # Password from a Nomad variable (see the prerequisites above), not from the job file.
      # Tasks can read variables under nomad/jobs/<job-name> without an ACL policy.
      template {
        destination = "secrets/postgres.env"
        env         = true
        data        = <<EOF
POSTGRES_PASSWORD={{ with nomadVar "nomad/jobs/service-mesh-webapp" }}{{ .postgres_password }}{{ end }}
EOF
      }

      env {
        POSTGRES_DB   = "appdb"
        POSTGRES_USER = "appuser"
      }

      resources {
        cpu    = 300
        memory = 512
      }
    }
  }

  # Redis cache: the webapp's second upstream. Same pattern as postgres, no secrets.
  group "redis" {
    count = 1

    network {
      mode = "bridge"
      port "cache" { to = 6379 }
    }

    service {
      name     = "redis-cache"
      port     = "6379"
      provider = "consul"

      connect {
        sidecar_service {}
      }
      # No Nomad check here: tcp checks are not valid on Connect-enabled services. Consul checks the
      # sidecar proxy itself, and the webapp's /health check (with expose = true) covers the app path.
    }

    task "redis" {
      driver = "docker"

      config {
        image = "redis:8-alpine"
        ports = ["cache"]
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
