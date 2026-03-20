# L-MAX: Nomad — Parameterized Job with Dispatch
# A parameterized job is a job template that is instantiated on-demand via dispatch.
# Each dispatch creates a child job (batch allocation) with custom payload/metadata.
# Use cases: data processing pipelines, report generation, one-off task execution.
#
# Dispatch (trigger a run):
#   nomad job dispatch -meta REPORT_TYPE=daily -meta OUTPUT_FORMAT=csv \
#     batch-report-generator @/path/to/input-data.json
#
# List dispatched jobs:
#   nomad job status batch-report-generator
#
# View child job logs:
#   nomad alloc logs <alloc-id> report-task

job "batch-report-generator" {
  datacenters = ["dc1"]

  # type = "batch" — allocations run to completion (exit 0) then stop
  type = "batch"

  # parameterized block makes this a job template (not immediately scheduled)
  parameterized {
    # payload: the dispatch payload (arbitrary bytes, e.g. JSON input data)
    payload = "optional"    # "required" | "optional" | "forbidden"

    # meta_required: dispatch must provide these metadata keys
    meta_required = ["REPORT_TYPE"]

    # meta_optional: dispatch may provide these keys (defaults apply if absent)
    meta_optional = ["OUTPUT_FORMAT", "NOTIFY_EMAIL"]
  }

  group "report" {
    count = 1    # Each dispatch creates exactly 1 allocation

    # Reschedule: don't reschedule batch jobs on failure (let them fail fast)
    reschedule {
      attempts  = 0
      unlimited = false
    }

    # Restart: retry up to 2 times within the allocation before failing
    restart {
      attempts = 2
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "report-task" {
      driver = "docker"

      config {
        image   = "myreport-generator:2.1.0"
        command = "/app/generate-report"
        args = [
          "--type",   "${NOMAD_META_REPORT_TYPE}",    # Injected from dispatch metadata
          "--format", "${NOMAD_META_OUTPUT_FORMAT}",
          "--output", "/output/report.${NOMAD_META_OUTPUT_FORMAT}",
        ]
      }

      # Write the dispatch payload to a file for the task to consume
      dispatch_payload {
        file = "input/data.json"    # Written to ${NOMAD_TASK_DIR}/input/data.json
      }

      # Template: render output path and notification config from metadata
      template {
        destination = "local/config.env"
        env         = true
        data        = <<EOF
REPORT_TYPE={{ env "NOMAD_META_REPORT_TYPE" }}
OUTPUT_FORMAT={{ or (env "NOMAD_META_OUTPUT_FORMAT") "json" }}
NOTIFY_EMAIL={{ or (env "NOMAD_META_NOTIFY_EMAIL") "ops@example.com" }}
JOB_ID={{ env "NOMAD_JOB_ID" }}
ALLOC_ID={{ env "NOMAD_ALLOC_ID" }}
EOF
      }

      # Ephemeral disk for output files (shared across tasks in group)
      # Migrated to new allocation on reschedule if sticky = true
      ephemeral_disk {
        size    = 500    # MB
        sticky  = false
        migrate = false
      }

      resources {
        cpu    = 500
        memory = 512
      }

      # Artifact: download input schema from object storage before running
      artifact {
        source      = "https://artifacts.example.com/schemas/report-schema-v2.json"
        destination = "local/schema.json"
      }

      logs {
        max_files     = 3
        max_file_size = 10    # MB per log file
      }

      env {
        OUTPUT_DIR   = "${NOMAD_TASK_DIR}/output"
        INPUT_FILE   = "${NOMAD_TASK_DIR}/input/data.json"
        SCHEMA_FILE  = "${NOMAD_TASK_DIR}/local/schema.json"
      }
    }
  }
}
