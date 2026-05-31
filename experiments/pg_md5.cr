require "../src/aptork"
conn = Aptork::PostgresConnection.connect("postgres://md5user:md5pw@127.0.0.1:55432/aptork_test")
store = Aptork::SqlKvStore.new(conn, dialect: Aptork::SqlDialect::Postgres, table: "md5kv")
store.set("k", "v"); puts "md5 auth + get => #{store.get("k").inspect}"
conn.close
