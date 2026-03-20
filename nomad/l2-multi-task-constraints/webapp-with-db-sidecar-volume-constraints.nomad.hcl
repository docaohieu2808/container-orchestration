# L2: Nomad — Multi-Task Group with Sidecar, Constraints, and Volumes
# A group can contain multiple tasks that co-locate on the same Nomad client node.
# Tasks in a group share network namespace and can communicate via localhost.
# Constraints restrict placement to nodes matching hardware/metadata requirements.
# CSI volumes or host volumes provide persistent storage for stateful tasks.
#
# Pattern: webapp (main) + log-shipper (sidecar) in same allocation

job "webapp-with-db-sidecar" {
  datacenters = ["dc1"]
  type        = "service"
  namespace   = "default"

  # Constraint: only schedule on nodes with linux kernel (amd64)
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  # Constraint: only schedule on nodes tagged as "worker" class
  constraint {
    attribute = "${node.class}"
    value     = "worker"
  }

  update {
    max_parallel     = 1
    min_healthy_time = "10s"
    healthy_deadline = "3m"
    auto_revert      = true
    canary           = 1    # Deploy 1 canary before rolling out to all allocations
  }

  group "webapp" {
    count = 2

    # Spread allocations across distinct hosts (avoid co-location)
    spread {
      attribute = "${node.unique.id}"
      weight    = 100
    }

    network {
      port "http" { to = 8080 }      # Dynamic host port -> container port 8080
      port "metrics" { to = 9090 }   # Prometheus metrics sidecar
    }

    # Host volume for persistent app data (configured in Nomad agent config)
    volume "app-data" {
      type      = "host"
      read_only = false
      source    = "app-data-vol"    # Must match volume name in agent config
    }

    service {
      name     = "webapp"
      port     = "http"
      provider = "consul"
      tags     = ["urlprefix-/webapp"]    # Fabio/Traefik routing tag

      check {
        type     = "http"
        path     = "/health"
        interval = "15s"
        timeout  = "3s"
      }
    }

    # Main application task
    task "webapp" {
      driver = "docker"

      config {
        image = "myapp:1.2.3"
        ports = ["http"]
      }

      volume_mount {
        volume      = "app-data"
        destination = "/data"         # Mount path inside container
        read_only   = false
      }

      # Render DB credentials from Vault (Nomad + Vault integration)
      template {
        destination = "secrets/db.env"
        env         = true            # Inject rendered vars as environment variables
        data        = <<EOF
{{ with secret "database/creds/webapp" }}
DB_USERNAME={{ .Data.username }}
DB_PASSWORD={{ .Data.password }}
{{ end }}
EOF
      }

      resources {
        cpu    = 200
        memory = 256
      }

      # Vault policy for dynamic secret injection
      vault {
        policies = ["webapp-db-policy"]
      }

      env {
        APP_ENV  = "production"
        APP_PORT = "${NOMAD_PORT_http}"
      }
    }

    # Sidecar task: Fluent Bit log shipper (co-located, shares network with webapp)
    task "log-shipper" {
      driver = "docker"

      # Lifecycle: sidecar runs alongside main task
      lifecycle {
        hook    = "poststart"   # Start after main task is running
        sidecar = true          # Keep running as long as main task runs
      }

      config {
        image = "fluent/fluent-bit:2.2"
        args  = ["-c", "/fluent-bit/etc/fluent-bit.conf"]
      }

      template {
        destination = "local/fluent-bit.conf"
        data        = <<EOF
[SERVICE]
    Flush        5
    Log_Level    info

[INPUT]
    Name         forward
    Listen       127.0.0.1
    Port         24224

[OUTPUT]
    Name         stdout
    Match        *
EOF
      }

      resources {
        cpu    = 50
        memory = 64
      }
    }
  }
}
