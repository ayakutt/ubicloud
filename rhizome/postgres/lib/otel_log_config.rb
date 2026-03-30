# frozen_string_literal: true

require "yaml"

# Generates OpenTelemetry Collector YAML configuration for shipping PostgreSQL
# logs to user-configured syslog destinations (RFC 5424 over TLS).
#
# Produces a unified log schema across two sources:
#   filelog/pglog  — PostgreSQL JSON log files → stream: "postgres"
#   journald       — systemd journal units   → stream: "postgres" | "pgbouncer" | "upgrade"
#
# Unified fields emitted for every log record:
#   body             Log message text
#   severity_number  OTel native severity level (set via severity_parser)
#   severity_text    OTel native severity label
#   stream           Source category: postgres / pgbouncer / upgrade
#   instance         Ubid of the PostgresServer that produced this log
#   server_role      Role of the server: primary / standby
#
# pglog-only attributes (passed through from PostgreSQL JSON format):
#   pid, session_id, session_start, txid, vxid, backend_type,
#   dbname, remote_host, remote_port, query_id, detail, state_code
#
# RFC 5424 syslog header fields (mapped from log attributes by the syslog exporter):
#   HOSTNAME = postgres server ubid  (attributes["hostname"])
#   APP-NAME = postgres resource name  (attributes["appname"], set per-destination via transform)
#   MSG      = message text  (attributes["message"])
class OtelLogConfig
  def initialize(instance:, server_role:, log_dir:, log_destinations:)
    @instance = instance
    @server_role = server_role
    @log_dir = log_dir
    @log_destinations = log_destinations
  end

  def to_config
    YAML.dump(config_hash)
  end

  private

  def config_hash
    {
      "extensions" => extensions_hash,
      "receivers" => receivers_hash,
      "processors" => processors_hash,
      "exporters" => exporters_hash,
      "service" => service_hash,
    }
  end

  def extensions_hash
    {
      "health_check" => {"endpoint" => "0.0.0.0:13133"},
      "file_storage/state" => {
        "directory" => "/var/lib/otelcol-contrib/state",
        "create_directory" => true,
        "compaction" => {
          "directory" => "/tmp/otelcol",
          "on_start" => true,
          "on_rebound" => true,
          "rebound_needed_threshold_mib" => 1024,
          "rebound_trigger_threshold_mib" => 100,
        },
      },
    }
  end

  def receivers_hash
    {
      "filelog/pglog" => filelog_receiver_hash,
      "journald" => journald_receiver_hash,
    }
  end

  def filelog_receiver_hash
    {
      "include" => ["#{@log_dir}/postgresql-*.json"],
      "start_at" => "end",
      "storage" => "file_storage/state",
      "operators" => [
        {
          "id" => "parse_json",
          "type" => "json_parser",
          "on_error" => "send",
          "timestamp" => {
            "parse_from" => "attributes.timestamp",
            "layout" => "2006-01-02 15:04:05.000 UTC",
            "layout_type" => "gotime",
          },
          "severity" => {
            "parse_from" => "attributes.error_severity",
            "preset" => "none",
            "mapping" => {
              "fatal" => ["FATAL", "PANIC"],
              "error" => "ERROR",
              "warn" => "WARNING",
              "info3" => "NOTICE",
              "info" => ["INFO", "LOG"],
              "debug" => ["DEBUG", "DEBUG1", "DEBUG2", "DEBUG3", "DEBUG4", "DEBUG5"],
            },
          },
        },
        {"type" => "copy", "from" => "attributes.message", "to" => "body"},
        {"type" => "remove", "field" => "attributes.error_severity"},
        {"type" => "add", "field" => "attributes.stream", "value" => "postgres"},
        {"type" => "add", "field" => "attributes.instance", "value" => @instance},
        {"type" => "add", "field" => "attributes.server_role", "value" => @server_role},
        {"type" => "add", "field" => "attributes.hostname", "value" => @instance},
        {"type" => "remove", "field" => "attributes.timestamp"},
      ],
    }
  end

  def journald_receiver_hash
    {
      "storage" => "file_storage/state",
      "operators" => [
        {
          "id" => "filter_units",
          "type" => "router",
          "routes" => [
            {"output" => "mark_postgres_stream", "expr" => 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "postgresql@"'},
            {"output" => "mark_pgbouncer_stream", "expr" => 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "pgbouncer@"'},
            {"output" => "mark_upgrade_stream", "expr" => 'body["_SYSTEMD_UNIT"] != nil && body["_SYSTEMD_UNIT"] startsWith "upgrade_postgres"'},
          ],
        },
        {"id" => "mark_postgres_stream", "type" => "add", "field" => "attributes.stream", "value" => "postgres", "output" => "set_common_fields"},
        {"id" => "mark_pgbouncer_stream", "type" => "add", "field" => "attributes.stream", "value" => "pgbouncer", "output" => "set_common_fields"},
        {"id" => "mark_upgrade_stream", "type" => "add", "field" => "attributes.stream", "value" => "upgrade", "output" => "set_common_fields"},
        {"id" => "set_common_fields", "type" => "add", "field" => "attributes.instance", "value" => @instance},
        {"type" => "add", "field" => "attributes.server_role", "value" => @server_role},
        {"type" => "add", "field" => "attributes.hostname", "value" => @instance},
        {"type" => "move", "from" => "body", "to" => "attributes.journald"},
        {"type" => "copy", "from" => 'attributes.journald["MESSAGE"]', "to" => "attributes.message"},
        {"type" => "move", "from" => 'attributes.journald["MESSAGE"]', "to" => "body"},
        {"type" => "flatten", "field" => "attributes.journald"},
        {"type" => "move", "from" => 'attributes["_PID"]', "to" => "attributes.pid"},
        {
          "id" => "parse_journald_severity",
          "type" => "severity_parser",
          "parse_from" => 'attributes["PRIORITY"]',
          "preset" => "none",
          "mapping" => {
            "fatal" => ["0", "1", "2"],
            "error" => "3",
            "warn" => "4",
            "info3" => "5",
            "info" => "6",
            "debug" => "7",
          },
        },
        {
          "type" => "retain",
          "fields" => [
            "body",
            "attributes.message",
            "attributes.stream",
            "attributes.instance",
            "attributes.server_role",
            "attributes.hostname",
            "attributes.pid",
          ],
        },
      ],
    }
  end

  def processors_hash
    hash = {"batch" => nil}
    @log_destinations.each_with_index do |dest, i|
      statements = []
      (dest["structured_data"] || {}).each do |sd_id, params|
        params.each do |key, value|
          statements << "set(log.attributes[\"structured_data\"][\"#{ottl_escape(sd_id)}\"][\"#{ottl_escape(key)}\"], \"#{ottl_escape(value)}\")"
        end
      end
      next if statements.empty?

      hash["transform/dest#{i}"] = {
        "log_statements" => [{"context" => "log", "statements" => statements}],
      }
    end
    hash
  end

  def exporters_hash
    @log_destinations.each_with_index.to_h do |dest, i|
      ["syslog/dest#{i}", {
        "endpoint" => dest["host"],
        "port" => dest["port"],
        "network" => "tcp",
        "protocol" => "rfc5424",
        "tls" => {"insecure" => false},
      }]
    end
  end

  def service_hash
    {
      "extensions" => ["health_check", "file_storage/state"],
      "pipelines" => pipelines_hash,
    }
  end

  def pipelines_hash
    @log_destinations.each_with_index.flat_map do |dest, i|
      has_transform = dest["structured_data"]&.any? { |_, params| params.any? }
      [
        ["logs/pglog/dest#{i}", {
          "receivers" => ["filelog/pglog"],
          "processors" => has_transform ? ["transform/dest#{i}", "batch"] : ["batch"],
          "exporters" => ["syslog/dest#{i}"],
        }],
        ["logs/journal/dest#{i}", {
          "receivers" => ["journald"],
          "processors" => has_transform ? ["transform/dest#{i}", "batch"] : ["batch"],
          "exporters" => ["syslog/dest#{i}"],
        }],
      ]
    end.to_h
  end

  def ottl_escape(value)
    value.to_s.gsub("\\", "\\\\").gsub('"', '\\"')
  end
end
