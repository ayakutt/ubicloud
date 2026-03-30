# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "cli pg add-log-destination" do
  before do
    expect(Config).to receive(:postgres_service_project_id).and_return(@project.id).at_least(:once)
  end

  it "adds a log destination to the database" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    expect(pg.log_destinations_dataset).to be_empty
    body = cli(%w[pg eu-central-h1/test-pg add-log-destination my-dest logs.example.com 6514])
    expect(pg.log_destinations_dataset.count).to eq 1
    ld = pg.log_destinations.first
    expect(body).to eq <<~END
      Log destination added to PostgreSQL database.
      Current log destinations:
        1: #{ld.ubid}  my-dest  logs.example.com  6514
    END
    expect(ld.name).to eq "my-dest"
    expect(ld.host).to eq "logs.example.com"
    expect(ld.port).to eq 6514
    expect(ld.structured_data).to be_nil
  end

  it "adds a log destination with structured data" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    pg = PostgresResource.first
    cli(["pg", "eu-central-h1/test-pg", "add-log-destination", "my-dest", "logs.example.com", "6514",
      "honeybadger@61642/api_key=secret", "honeybadger@61642/env=prod", "logdna@48950/api_key=abc"])
    ld = pg.log_destinations.first
    expect(ld.structured_data).to eq({
      "honeybadger@61642" => {"api_key" => "secret", "env" => "prod"},
      "logdna@48950" => {"api_key" => "abc"},
    })
  end

  it "returns an error for structured_data arg missing slash or equals" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    body = cli(%w[pg eu-central-h1/test-pg add-log-destination my-dest logs.example.com 6514 badarg], status: 400)
    expect(body).to include("Invalid structured_data argument, expected sd-id/key=value format").and include('"badarg"')
  end

  it "returns an error for structured_data arg with equals only before the slash" do
    cli(%w[pg eu-central-h1/test-pg create -s standard-2 -S 64])
    body = cli(["pg", "eu-central-h1/test-pg", "add-log-destination", "my-dest", "logs.example.com", "6514", "foo=bar/baz"], status: 400)
    expect(body).to include("Invalid structured_data argument, expected sd-id/key=value format").and include('"foo=bar/baz"')
  end
end
