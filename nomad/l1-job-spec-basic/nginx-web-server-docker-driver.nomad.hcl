# L1: Nomad — Basic Job Spec (Docker Driver)
# A Nomad job is the top-level unit of work. It contains:
#   job -> group -> task
# The Docker task driver pulls and runs container images via the Docker daemon.
# Nomad handles scheduling, health checking, and restart policies.
#
# Apply: nomad job run nginx-web-server-docker-driver.nomad.hcl
# Status: nomad job status nginx-web
# Logs:   nomad alloc logs <alloc-id>

job "nginx-web" {
  # Datacenter where this job can be placed (must match agent config)
  datacenters = ["dc1"]

  # Job type: service (long-running), batch (finite), system (every node), sysbatch
  type = "service"

  # Namespace for multi-tenant isolation (Nomad Enterprise or OSS 1.0+)
  namespace = "default"

  # Update policy: rolling update with canary support
  update {
    max_parallel      = 1       # Update 1 allocation at a time
    min_healthy_time  = "10s"   # Allocation must be healthy for 10s before proceeding
    healthy_deadline  = "3m"    # Fail update if not healthy within 3 minutes
    auto_revert       = true    # Revert to previous version if update fails
  }

  group "web" {
    # Number of allocations (analogous to Deployment replicas)
    count = 2

    # Network configuration for the group
    network {
      port "http" {
        static = 8080   # Bind to static port 8080 on the host
        # to = 80       # Map host port to container port 80 (use with dynamic ports)
      }
    }

    # Health check via Consul service registration
    service {
      name     = "nginx-web"
      port     = "http"
      provider = "consul"   # Use "nomad" if Consul is not installed

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }

    # Restart policy: restart failed allocations before rescheduling
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay"   # "delay" = wait before retry; "fail" = fail immediately
    }

    task "nginx" {
      # Docker task driver: runs a container image
      driver = "docker"

      config {
        image = "nginx:1.25-alpine"
        ports = ["http"]      # Expose the "http" port defined in network block

        # Mount a custom config file into the container
        volumes = [
          "local/nginx.conf:/etc/nginx/conf.d/default.conf"
        ]
      }

      # Inline file rendered by Nomad template engine (Go templates + Consul KV)
      template {
        destination = "local/nginx.conf"
        data        = <<EOF
server {
    listen {{ env "NOMAD_PORT_http" }};  # Use dynamic Nomad-assigned port
    server_name _;

    location / {
        root  /usr/share/nginx/html;
        index index.html;
    }

    location /health {
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}
EOF
      }

      # Resource constraints (Nomad bin-packs tasks onto nodes)
      resources {
        cpu    = 100   # MHz
        memory = 128   # MB
      }

      # Environment variables
      env {
        APP_ENV = "production"
      }
    }
  }
}
