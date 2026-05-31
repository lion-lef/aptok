require "../src/aptok"
require "../src/store/postgres"

conn = Aptok::PostgresConnection.connect("postgres://md5user:md5pw@127.0.0.1:55432/aptok_test")
store = Aptok::SqlKvStore.new(conn, table: "md5kv")
store.set("k", "v"); puts "md5 auth + get => #{store.get("k").inspect}"
conn.close
