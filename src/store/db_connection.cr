require "db"

module Aptok
  # Adapter from Crystal's `DB::Database` API to the narrow SQL surface used by
  # `SqlKvStore` and `SqlMessageQueue`.
  class DbConnection
    include SqlConnection

    getter database : ::DB::Database
    getter dialect : SqlDialect

    def initialize(@database : ::DB::Database, @dialect : SqlDialect)
    end

    def execute(sql : String, args : Array(SqlValue)) : Int64
      @database.exec(sql, args: db_args(args)).rows_affected
    end

    def query(sql : String, args : Array(SqlValue)) : Array(Array(SqlValue))
      rows = [] of Array(SqlValue)
      @database.query(sql, args: db_args(args)) do |rs|
        rs.each do
          row = Array(SqlValue).new(rs.column_count)
          rs.column_count.times do
            row << sql_value(rs.read)
          end
          rows << row
        end
      end
      rows
    end

    def close : Nil
      @database.close
    end

    private def db_args(args : Array(SqlValue)) : Array(::DB::Any)
      args.map do |arg|
        case arg
        when Int32  then arg.as(::DB::Any)
        when Int64  then arg.as(::DB::Any)
        when String then arg.as(::DB::Any)
        else             nil.as(::DB::Any)
        end
      end
    end

    private def sql_value(value) : SqlValue
      case value
      when Int8, Int16, Int32, UInt8, UInt16, UInt32
        value.to_i64
      when UInt64
        value <= Int64::MAX.to_u64 ? value.to_i64 : nil
      when Int64
        value
      when String
        value
      else
        nil
      end
    end
  end
end
