require "../src/aptork"
require "../src/store/postgres"

conn = Aptork::PostgresConnection.connect("postgres://md5user:md5pw@127.0.0.1:55432/aptork_test")
store = Aptork::SqlKvStore.new(conn, table: "md5kv")
store.set("k", "v"); puts "md5 auth + get => #{store.get("k").inspect}"
conn.close
