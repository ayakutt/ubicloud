# frozen_string_literal: true

require "yaml"
require_relative "../lib/otel_log_config"

RSpec.describe OtelLogConfig do
  let(:instance) { "pg1abc2def3" }
  let(:server_role) { "primary" }
  let(:log_dir) { "/dat/17/data/pg_log" }
  let(:log_destinations) { [] }
  let(:config) { described_class.new(instance: instance, server_role: server_role, log_dir: log_dir, log_destinations: log_destinations) }
  let(:parsed) { YAML.safe_load(config.to_config) }

  describe "#to_config" do
    it "includes health_check and file_storage extensions" do
      expect(parsed["extensions"]).to have_key("health_check")
      expect(parsed["extensions"]).to have_key("file_storage/state")
    end

    it "configures the pglog filelog receiver with the correct log dir" do
      expect(parsed["receivers"]["filelog/pglog"]["include"]).to include("/dat/17/data/pg_log/postgresql-*.json")
    end

    it "tags pglog events with instance and server_role" do
      pglog_ops = parsed["receivers"]["filelog/pglog"]["operators"]
      expect(pglog_ops.select { |op| op["field"] == "attributes.instance" }.map { |op| op["value"] }).to all(eq("pg1abc2def3"))
      expect(pglog_ops.select { |op| op["field"] == "attributes.server_role" }.map { |op| op["value"] }).to all(eq("primary"))
    end

    it "sets hostname to the instance ubid in the pglog receiver" do
      pglog_ops = parsed["receivers"]["filelog/pglog"]["operators"]
      expect(pglog_ops).to include(include("field" => "attributes.hostname", "value" => "pg1abc2def3"))
    end

    it "configures the journald receiver" do
      expect(parsed["receivers"]).to have_key("journald")
    end

    it "filters journal to postgres-related units" do
      routes = parsed["receivers"]["journald"]["operators"].find { |op| op["id"] == "filter_units" }["routes"]
      exprs = routes.map { |r| r["expr"] }
      expect(exprs).to include(a_string_including('startsWith "postgresql@"'))
      expect(exprs).to include(a_string_including('startsWith "pgbouncer@"'))
      expect(exprs).to include(a_string_including('startsWith "upgrade_postgres"'))
    end

    it "marks journal streams correctly" do
      op_ids = parsed["receivers"]["journald"]["operators"].filter_map { |op| op["id"] }
      expect(op_ids).to include("mark_postgres_stream", "mark_pgbouncer_stream", "mark_upgrade_stream")
    end

    it "includes a batch processor" do
      expect(parsed["processors"]).to have_key("batch")
    end

    it "lists health_check and file_storage in service extensions" do
      expect(parsed["service"]["extensions"]).to contain_exactly("health_check", "file_storage/state")
    end

    context "with no destinations" do
      let(:log_destinations) { [] }

      it "produces no exporters" do
        expect(parsed["exporters"]).to be_empty
      end

      it "produces no transform processors" do
        expect(parsed["processors"].keys).not_to include(a_string_starting_with("transform/"))
      end

      it "produces no pipelines" do
        expect(parsed["service"]["pipelines"]).to be_empty
      end
    end

    context "with one destination and no structured_data" do
      let(:log_destinations) do
        [{"host" => "logs.example.com", "port" => 6514, "structured_data" => nil}]
      end

      it "creates a syslog exporter with the correct host and port" do
        exporter = parsed["exporters"]["syslog/dest0"]
        expect(exporter["endpoint"]).to eq("logs.example.com")
        expect(exporter["port"]).to eq(6514)
      end

      it "uses TCP with RFC 5424" do
        exporter = parsed["exporters"]["syslog/dest0"]
        expect(exporter["network"]).to eq("tcp")
        expect(exporter["protocol"]).to eq("rfc5424")
      end

      it "enables TLS" do
        expect(parsed["exporters"]["syslog/dest0"]["tls"]["insecure"]).to be false
      end

      it "creates pglog and journal pipelines for the destination" do
        expect(parsed["service"]["pipelines"]).to have_key("logs/pglog/dest0")
        expect(parsed["service"]["pipelines"]).to have_key("logs/journal/dest0")
      end

      it "produces no transform processor" do
        expect(parsed["processors"].keys).not_to include("transform/dest0")
      end

      it "uses only batch in the pipeline processors" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest0"]
        expect(pglog["processors"]).to eq(["batch"])
      end
    end

    context "with structured_data" do
      let(:log_destinations) do
        [{
          "host" => "logs.example.com",
          "port" => 6514,
          "structured_data" => {
            "honeybadger@61642" => {"api_key" => "secret", "env" => "prod"},
          },
        }]
      end

      it "creates a transform processor for the destination" do
        expect(parsed["processors"]).to have_key("transform/dest0")
      end

      it "emits structured_data set statements in the transform processor" do
        statements = parsed["processors"]["transform/dest0"]["log_statements"].flat_map { |s| s["statements"] }
        expect(statements).to include(a_string_including('attributes["structured_data"]["honeybadger@61642"]["api_key"], "secret"'))
        expect(statements).to include(a_string_including('attributes["structured_data"]["honeybadger@61642"]["env"], "prod"'))
      end

      it "includes the transform processor in the pipeline" do
        pglog = parsed["service"]["pipelines"]["logs/pglog/dest0"]
        expect(pglog["processors"]).to eq(["transform/dest0", "batch"])
      end
    end

    context "with multiple destinations" do
      let(:log_destinations) do
        [
          {"host" => "logs1.example.com", "port" => 6514, "structured_data" => nil},
          {"host" => "logs2.example.com", "port" => 6515, "structured_data" => nil},
        ]
      end

      it "creates a separate exporter for each destination" do
        expect(parsed["exporters"]).to have_key("syslog/dest0")
        expect(parsed["exporters"]).to have_key("syslog/dest1")
      end

      it "uses the correct host and port for each destination" do
        expect(parsed["exporters"]["syslog/dest0"]["endpoint"]).to eq("logs1.example.com")
        expect(parsed["exporters"]["syslog/dest0"]["port"]).to eq(6514)
        expect(parsed["exporters"]["syslog/dest1"]["endpoint"]).to eq("logs2.example.com")
        expect(parsed["exporters"]["syslog/dest1"]["port"]).to eq(6515)
      end

      it "creates pglog and journal pipelines for each destination" do
        pipelines = parsed["service"]["pipelines"]
        expect(pipelines).to have_key("logs/pglog/dest0")
        expect(pipelines).to have_key("logs/pglog/dest1")
        expect(pipelines).to have_key("logs/journal/dest0")
        expect(pipelines).to have_key("logs/journal/dest1")
      end
    end

    context "with structured_data value containing double quotes" do
      let(:log_destinations) do
        [{"host" => "logs.example.com", "port" => 6514, "structured_data" => {"sd@1" => {"key" => 'val"ue'}}}]
      end

      it "escapes double quotes in structured_data values" do
        statements = parsed["processors"]["transform/dest0"]["log_statements"].flat_map { |s| s["statements"] }
        expect(statements).to include(a_string_including('["key"], "val\\"ue"'))
      end
    end
  end
end
