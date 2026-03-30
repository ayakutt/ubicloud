# frozen_string_literal: true

UbiCli.on("pg").run_on("add-log-destination") do
  desc "Add a PostgreSQL log destination"

  banner "ubi pg (location/pg-name | pg-id) add-log-destination name host port [sd-id/key=value [...]]"

  args(3..)

  run do |args, _, cmd|
    name, host, port, *sd_args = args
    structured_data = structured_data_args_to_hash(sd_args, cmd)
    data = sdk_object.add_log_destination(name:, host:, port: need_integer_arg(port, "port", cmd), structured_data:)
    body = []
    body << "Log destination added to PostgreSQL database.\n"
    body << "Current log destinations:\n"
    data[:log_destinations].each_with_index do |ld, i|
      body << "  " << (i + 1).to_s << ": " << ld[:id] << "  " << ld[:name] << "  " << ld[:host] << "  " << ld[:port].to_s << "\n"
    end
    response(body)
  end
end
