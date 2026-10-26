# L2: Nomad — Multi-Task Group with Sidecar, Constraints, Volumes and Vault
# A group can contain multiple tasks that co-locate on the same Nomad client node.
# Tasks in a group share network namespace and can communicate via localhost.
# Constraints restrict placement to nodes matching hardware/metadata requirements.
# Host volumes provide persistent storage for stateful tasks.
#
# Pattern: webapp (main) + log-shipper (sidecar) in same allocation, database credentials from Vault.
#
# This job needs infrastructure a laptop does not have, so CI validates it (`nomad job validate`)
# but does not run it. `myapp:1.2.3` is a placeholder for your own image. To run it you need:
#   - client nodes with `node_class = "worker"` and a host volume named app-data-vol (client config)
#   - Vault with the database secrets engine (a `webapp` role) and Nomad's Vault integration using
#     workload identity: a `vault` block in the server/client agent config, Vault's JWT auth method
#     trusting Nomad's JWKS endpoint, and a role named below. The old token-based flow
#     (`vault { policies = [...] }` in the job) was removed in Nomad 1.10.

job "webapp-with-db-sidecar" {
  datacenters = ["dc1"]
  type        = "service"
  namespace   = "default"

  # Constraint: only schedule on Linux clients
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
    canary           = 1 # Deploy 1 canary before rolling out to all allocations
  }

  group "webapp" {
    count = 2

    # Spread allocations across distinct hosts (avoid co-location)
    spread {
      attribute = "${node.unique.id}"
      weight    = 100
    }

    network {
      port "http" { to = 8080 } # Dynamic host port -> container port 8080
    }

    # Host volume for persistent app data (configured in the Nomad client config)
    volume "app-data" {
      type      = "host"
      read_only = false
      source    = "app-data-vol" # Must match volume name in client config
    }

    service {
      name     = "webapp"
      port     = "http"
      provider = "nomad"
      tags     = ["urlprefix-/webapp"] # Fabio/Traefik routing tag

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
        destination = "/data" # Mount path inside container
        read_only   = false
      }

      # Vault access through workload identity: Nomad signs a JWT for this task, Vault's JWT auth
      # method exchanges it for a token carrying the policies bound to `role`. No static token.
      vault {
        role        = "webapp-db" # Vault JWT-auth role (it holds the policies, e.g. webapp-db-policy)
        change_mode = "restart"   # Restart the task when the rendered secret changes
      }

      # Render DB credentials from Vault's database secrets engine
      template {
        destination = "secrets/db.env"
        env         = true # Inject rendered vars as environment variables
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

      env {
        APP_ENV  = "production"
        APP_PORT = "8080"
      }
    }

    # Sidecar task: Fluent Bit log shipper (co-located, shares network with webapp)
    task "log-shipper" {
      driver = "docker"

      # Lifecycle: sidecar runs alongside main task
      lifecycle {
        hook    = "poststart" # Start after main task is running
        sidecar = true        # Keep running as long as main task runs
      }

      config {
        image = "fluent/fluent-bit:5.1.5"
        args  = ["-c", "/fluent-bit/etc/fluent-bit.conf"]

        # The template below renders into the task dir; mount it where Fluent Bit looks for its config,
        # otherwise the image's default configuration is used and the rendered file is ignored.
        volumes = [
          "local/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf"
        ]
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
