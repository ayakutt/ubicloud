# frozen_string_literal: true

require_relative "../../model"

class PostgresLogDestination < Sequel::Model
  many_to_one :postgres_resource

  plugin ResourceMethods, encrypted_columns: {structured_data: {format: :json}}
end

# Table: postgres_log_destination
# Columns:
#  id                   | uuid    | PRIMARY KEY DEFAULT gen_random_ubid_uuid(45)
#  postgres_resource_id | uuid    | NOT NULL
#  name                 | text    | NOT NULL
#  host                 | text    | NOT NULL
#  port                 | integer | NOT NULL
#  structured_data      | text    |
# Indexes:
#  postgres_log_destination_pkey | PRIMARY KEY btree (id)
# Foreign key constraints:
#  postgres_log_destination_postgres_resource_id_fkey | (postgres_resource_id) REFERENCES postgres_resource(id)
