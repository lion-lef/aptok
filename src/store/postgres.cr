require "../aptork"
require "pg"
require "./db_connection"

module Aptork
  # A `SqlConnection` backed by `will/crystal-pg` through Crystal's `DB` API.
  #
  # ```
  # conn = Aptork::PostgresConnection.connect("postgres://user:pass@localhost/aptork")
  # store = Aptork::SqlKvStore.new(conn)
  # queue = Aptork::SqlMessageQueue.new(conn)
  # ```
  class PostgresConnection < DbConnection
    def self.connect(url : String) : PostgresConnection
      new(::DB.open(url))
    end

    def initialize(database : ::DB::Database)
      super(database, SqlDialect::Postgres)
    end
  end
end
