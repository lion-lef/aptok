require "../aptok"
require "pg"
require "./db_connection"

module Aptok
  # A `SqlConnection` backed by `will/crystal-pg` through Crystal's `DB` API.
  #
  # ```
  # conn = Aptok::PostgresConnection.connect("postgres://user:pass@localhost/aptok")
  # store = Aptok::SqlKvStore.new(conn)
  # queue = Aptok::SqlMessageQueue.new(conn)
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
