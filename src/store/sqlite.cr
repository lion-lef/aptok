require "../aptok"
require "sqlite3"
require "uri"
require "./db_connection"

module Aptok
  # A `SqlConnection` backed by `crystal-lang/crystal-sqlite3` through
  # Crystal's `DB` API.
  #
  # This driver is **not** required by `require "aptok"`, because it links
  # against SQLite at compile time. Pull it in explicitly when you want
  # SQLite-backed storage.
  #
  # ```
  # require "aptok"
  # require "aptok/store/sqlite"
  #
  # conn = Aptok::SqliteConnection.open("federation.db")
  # store = Aptok::SqlKvStore.new(conn)
  # queue = Aptok::SqlMessageQueue.new(conn)
  # ```
  #
  # Build with the system SQLite library available, e.g. `apt-get install
  # libsqlite3-dev` on Debian/Ubuntu or `brew install sqlite` on macOS.
  class SqliteConnection < DbConnection
    def self.open(path : String) : SqliteConnection
      new(::DB.open(sqlite_uri(path)))
    end

    def initialize(database : ::DB::Database)
      super(database, SqlDialect::Sqlite)
    end

    private def self.sqlite_uri(path : String) : String
      return path if path.starts_with?("sqlite3:")

      "sqlite3://#{URI.encode_path(path)}"
    end
  end
end
