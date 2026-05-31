require "../aptork"

module Aptork
  # A `SqlConnection` backed by the system `libsqlite3` via a thin FFI binding.
  #
  # This driver is **not** required by `require "aptork"`, because it links
  # against `libsqlite3` at compile time. Pull it in explicitly when you want
  # SQLite-backed storage:
  #
  # ```
  # require "aptork"
  # require "aptork/store/sqlite"
  #
  # conn = Aptork::SqliteConnection.open("federation.db")
  # store = Aptork::SqlKvStore.new(conn, dialect: Aptork::SqlDialect::Sqlite)
  # queue = Aptork::SqlMessageQueue.new(conn, dialect: Aptork::SqlDialect::Sqlite)
  # ```
  #
  # Build with the system SQLite library available, e.g. `apt-get install
  # libsqlite3-dev` on Debian/Ubuntu or `brew install sqlite` on macOS.
  class SqliteConnection
    include SqlConnection

    @[Link("sqlite3")]
    lib LibSQLite3
      type DB = Void*
      type Stmt = Void*

      OK   =   0
      ROW  = 100
      DONE = 101

      INTEGER = 1
      FLOAT   = 2
      TEXT    = 3
      BLOB    = 4
      NULL    = 5

      TRANSIENT = Pointer(Void).new(-1)

      fun open = sqlite3_open(filename : UInt8*, db : DB*) : Int32
      fun close = sqlite3_close(db : DB) : Int32
      fun errmsg = sqlite3_errmsg(db : DB) : UInt8*
      fun prepare_v2 = sqlite3_prepare_v2(db : DB, sql : UInt8*, n : Int32, stmt : Stmt*, tail : UInt8**) : Int32
      fun step = sqlite3_step(stmt : Stmt) : Int32
      fun finalize = sqlite3_finalize(stmt : Stmt) : Int32
      fun reset = sqlite3_reset(stmt : Stmt) : Int32
      fun changes = sqlite3_changes(db : DB) : Int32
      fun column_count = sqlite3_column_count(stmt : Stmt) : Int32
      fun column_type = sqlite3_column_type(stmt : Stmt, col : Int32) : Int32
      fun column_int64 = sqlite3_column_int64(stmt : Stmt, col : Int32) : Int64
      fun column_text = sqlite3_column_text(stmt : Stmt, col : Int32) : UInt8*
      fun bind_int64 = sqlite3_bind_int64(stmt : Stmt, idx : Int32, value : Int64) : Int32
      fun bind_text = sqlite3_bind_text(stmt : Stmt, idx : Int32, value : UInt8*, n : Int32, destructor : Void*) : Int32
      fun bind_null = sqlite3_bind_null(stmt : Stmt, idx : Int32) : Int32
    end

    # Opens (or creates) the SQLite database at *path*. Use `":memory:"` for an
    # in-memory database.
    def self.open(path : String) : SqliteConnection
      db = uninitialized LibSQLite3::DB
      rc = LibSQLite3.open(path.to_unsafe, pointerof(db))
      raise "sqlite3_open failed (#{rc}) for #{path}" unless rc == LibSQLite3::OK

      new(db)
    end

    def initialize(@db : LibSQLite3::DB)
      @mutex = Mutex.new
    end

    def execute(sql : String, args : Array(SqlValue)) : Int64
      @mutex.synchronize do
        with_statement(sql, args) do |stmt|
          rc = LibSQLite3.step(stmt)
          raise error("step") unless rc == LibSQLite3::DONE || rc == LibSQLite3::ROW
          LibSQLite3.changes(@db).to_i64
        end
      end
    end

    def query(sql : String, args : Array(SqlValue)) : Array(Array(SqlValue))
      @mutex.synchronize do
        with_statement(sql, args) do |stmt|
          rows = [] of Array(SqlValue)
          columns = LibSQLite3.column_count(stmt)
          loop do
            rc = LibSQLite3.step(stmt)
            break if rc == LibSQLite3::DONE
            raise error("step") unless rc == LibSQLite3::ROW

            row = Array(SqlValue).new(columns)
            columns.times do |col|
              row << read_column(stmt, col)
            end
            rows << row
          end
          rows
        end
      end
    end

    def close : Nil
      @mutex.synchronize do
        LibSQLite3.close(@db)
      end
    end

    private def with_statement(sql : String, args : Array(SqlValue), &)
      stmt = uninitialized LibSQLite3::Stmt
      rc = LibSQLite3.prepare_v2(@db, sql.to_unsafe, sql.bytesize, pointerof(stmt), nil)
      raise error("prepare") unless rc == LibSQLite3::OK

      begin
        bind(stmt, args)
        yield stmt
      ensure
        LibSQLite3.finalize(stmt)
      end
    end

    private def bind(stmt : LibSQLite3::Stmt, args : Array(SqlValue)) : Nil
      args.each_with_index do |value, index|
        position = index + 1
        case value
        when String
          LibSQLite3.bind_text(stmt, position, value.to_unsafe, value.bytesize, LibSQLite3::TRANSIENT.as(Void*))
        when Int64
          LibSQLite3.bind_int64(stmt, position, value)
        else
          LibSQLite3.bind_null(stmt, position)
        end
      end
    end

    private def read_column(stmt : LibSQLite3::Stmt, col : Int32) : SqlValue
      case LibSQLite3.column_type(stmt, col)
      when LibSQLite3::NULL
        nil
      when LibSQLite3::INTEGER
        LibSQLite3.column_int64(stmt, col)
      else
        ptr = LibSQLite3.column_text(stmt, col)
        ptr.null? ? nil : String.new(ptr)
      end
    end

    private def error(context : String) : Exception
      message = String.new(LibSQLite3.errmsg(@db))
      Exception.new("sqlite3 #{context} error: #{message}")
    end
  end
end
