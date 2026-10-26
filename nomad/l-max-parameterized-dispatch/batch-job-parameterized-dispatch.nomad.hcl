# L-MAX: Nomad — Parameterized Job with Dispatch
# A parameterized job is a job template that is instantiated on-demand via dispatch.
# Each dispatch creates a child job (batch allocation) with custom payload/metadata.
# Use cases: data processing pipelines, report generation, one-off task execution.
#
# Runs on a plain `nomad agent -dev` with Docker; CI does exactly that.
#
# Register the template (nothing runs yet):
#   nomad job run batch-job-parameterized-dispatch.nomad.hcl
# Dispatch (trigger a run) with metadata and a payload file:
#   echo '{"rows":[1,2,3]}' > input-data.json
#   nomad job dispatch -meta REPORT_TYPE=daily -meta OUTPUT_FORMAT=csv batch-report-generator input-data.json
# List dispatched children, then read the logs of one:
#   nomad job status batch-report-generator
#   nomad alloc logs -job batch-report-generator/dispatch-<id> report-task

job "batch-report-generator" {
  datacenters = ["dc1"]

  # type = "batch" — allocations run to completion (exit 0) then stop
  type = "batch"

  # Default metadata. A dispatch may override the keys listed in meta_optional; without a default
  # an omitted optional key would expand to an empty string in the task (${NOMAD_META_...}).
  meta {
    OUTPUT_FORMAT = "json"
    NOTIFY_EMAIL  = "ops@example.com"
  }

  # parameterized block makes this a job template (not immediately scheduled)
  parameterized {
    # payload: the dispatch payload (arbitrary bytes, e.g. JSON input data)
    payload = "optional"    # "required" | "optional" | "forbidden"

    # meta_required: dispatch must provide these metadata keys
    meta_required = ["REPORT_TYPE"]

    # meta_optional: dispatch may provide these keys (the defaults above apply if absent)
    meta_optional = ["OUTPUT_FORMAT", "NOTIFY_EMAIL"]
  }

  group "report" {
    count = 1    # Each dispatch creates exactly 1 allocation

    # Ephemeral disk for scratch/output files, shared by the tasks of the allocation.
    # It is a GROUP-level block (it is not valid inside a task).
    ephemeral_disk {
      size    = 300    # MB
      sticky  = false
      migrate = false
    }

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
        image   = "busybox:1.37"
        command = "/bin/sh"
        # A tiny stand-in for a real report generator: it shows how metadata, the payload and the
        # downloaded artifact reach the task. Swap the image/command for your own tool.
        args = [
          "-c",
          <<-SCRIPT
          set -eu
          echo "type=$REPORT_TYPE format=$OUTPUT_FORMAT notify=$NOTIFY_EMAIL job=$JOB_ID"
          echo "schema: $(head -c 60 "$SCHEMA_FILE" | tr -d '\n')"
          echo "payload bytes: $(wc -c < "$INPUT_FILE")"
          # /alloc is the allocation directory shared by all tasks; output survives the task.
          cp "$INPUT_FILE" "/alloc/data/report.$OUTPUT_FORMAT"
          echo "wrote /alloc/data/report.$OUTPUT_FORMAT"
          SCRIPT
        ]
      }

      # Write the dispatch payload to a file for the task to consume
      dispatch_payload {
        file = "input/data.json"    # Written to ${NOMAD_TASK_DIR}/input/data.json
      }

      # Template: render settings from the dispatch metadata into environment variables
      template {
        destination = "local/config.env"
        env         = true
        data        = <<EOF
REPORT_TYPE={{ env "NOMAD_META_REPORT_TYPE" }}
OUTPUT_FORMAT={{ env "NOMAD_META_OUTPUT_FORMAT" }}
NOTIFY_EMAIL={{ env "NOMAD_META_NOTIFY_EMAIL" }}
JOB_ID={{ env "NOMAD_JOB_ID" }}
EOF
      }

      resources {
        cpu    = 100
        memory = 64
      }

      # Artifact: download a file before the task starts. mode = "file" makes `destination` a file
      # path (the default "any" treats it as a directory). Relative paths are inside the task dir,
      # and ${NOMAD_TASK_DIR} is its local/ directory, so this lands at ${NOMAD_TASK_DIR}/schema.json.
      artifact {
        source      = "https://raw.githubusercontent.com/docaohieu2808/container-orchestration/main/nomad/l-max-parameterized-dispatch/report-schema.json"
        destination = "local/schema.json"
        mode        = "file"
      }

      logs {
        max_files     = 3
        max_file_size = 10    # MB per log file
      }

      env {
        INPUT_FILE  = "${NOMAD_TASK_DIR}/input/data.json"
        SCHEMA_FILE = "${NOMAD_TASK_DIR}/schema.json"
      }
    }
  }
}
