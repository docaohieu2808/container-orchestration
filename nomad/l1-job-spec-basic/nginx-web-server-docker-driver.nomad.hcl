# L1: Nomad — Basic Job Spec (Docker Driver)
# A Nomad job is the top-level unit of work. It contains:
#   job -> group -> task
# The Docker task driver pulls and runs container images via the Docker daemon.
# Nomad handles scheduling, health checking, and restart policies.
#
# Try it with no cluster at all (needs Docker and the nomad binary):
#   sudo nomad agent -dev                       # one-node server+client on 127.0.0.1:4646
#   nomad job run nginx-web-server-docker-driver.nomad.hcl
#   nomad job status nginx-web
#   nomad service info nginx-web                # address:port of each allocation
#   nomad alloc logs <alloc-id>

job "nginx-web" {
  # Datacenter where this job can be placed (must match agent config; -dev uses dc1)
  datacenters = ["dc1"]

  # Job type: service (long-running), batch (finite), system (every node), sysbatch
  type = "service"

  # Namespace for multi-tenant isolation (the "default" namespace always exists)
  namespace = "default"

  # Update policy: rolling update with canary support
  update {
    max_parallel     = 1     # Update 1 allocation at a time
    min_healthy_time = "10s" # Allocation must be healthy for 10s before proceeding
    healthy_deadline = "3m"  # Fail update if not healthy within 3 minutes
    auto_revert      = true  # Revert to previous version if update fails
  }

  group "web" {
    # Number of allocations (analogous to Deployment replicas)
    count = 2

    # Network configuration for the group
    network {
      port "http" {
        to = 80 # Dynamic host port -> container port 80. Two allocations can share one
        # host because each gets its own host port (a `static` port could not).
      }
    }

    # Health-checked service registration in Nomad's built-in service discovery.
    # Use provider = "consul" instead when a Consul agent is available (see l3).
    service {
      name     = "nginx-web"
      port     = "http"
      provider = "nomad"

      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }
    }

    # Restart policy: restart failed allocations before rescheduling
    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "delay" # "delay" = wait before retry; "fail" = fail immediately
    }

    task "nginx" {
      # Docker task driver: runs a container image
      driver = "docker"

      config {
        image = "nginx:1.30.6-alpine"
        ports = ["http"] # Expose the "http" port defined in network block

        # Mount the rendered config file into the container (relative paths resolve in the task dir)
        volumes = [
          "local/nginx.conf:/etc/nginx/conf.d/default.conf"
        ]
      }

      # Inline file rendered by the Nomad template engine (Go templates; can also read Nomad variables, Consul KV, Vault)
      template {
        destination = "local/nginx.conf"
        data        = <<EOF
server {
    listen 80;           # matches `to = 80` in the network block
    server_name _;

    location / {
        root  /usr/share/nginx/html;
        index index.html;
    }

    location /health {
        default_type text/plain;
        return 200 "OK\n";
    }
}
EOF
      }

      # Resource constraints (Nomad bin-packs tasks onto nodes)
      resources {
        cpu    = 100 # MHz
        memory = 128 # MB
      }

      # Environment variables
      env {
        APP_ENV = "production"
      }
    }
  }
}
