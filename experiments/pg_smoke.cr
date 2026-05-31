require "../src/aptok"
require "../src/store/postgres"

url = "postgres://aptok:secretpw@127.0.0.1:55432/aptok_test"
conn = Aptok::PostgresConnection.connect(url)
puts "connected (SCRAM ok)"

store = Aptok::SqlKvStore.new(conn, table: "kv_smoke")
store.set("actor:alice", "{\"name\":\"Alice\"}")
puts "get => #{store.get("actor:alice").inspect}"
puts "cas nil->v on existing => #{store.cas("actor:alice", nil, "X")}"
puts "cas match => #{store.cas("actor:alice", "{\"name\":\"Alice\"}", "v2")}"
puts "get => #{store.get("actor:alice").inspect}"
store.set("actor:bob", "b"); store.set("object:1", "o")
puts "list actor: => #{store.list("actor:").map(&.key)}"
store.set("temp", "v", ttl: 10.milliseconds)
sleep 30.milliseconds
puts "temp expired => #{store.get("temp").inspect}"

queue = Aptok::SqlMessageQueue.new(conn, table: "q_smoke")
queue.enqueue("inbox", Aptok::JsonMap{"a" => JSON::Any.new("1")})
queue.enqueue("inbox", Aptok::JsonMap{"a" => JSON::Any.new("2")})
puts "depth => #{queue.depth("inbox")}"
processed = [] of String
r = queue.process_one("inbox") { |m| processed << m.payload["a"].as_s }
puts "process => #{r} #{processed}"
puts "depth after => #{queue.depth("inbox")}"
pol = Aptok::RetryPolicy.new(max_attempts: 1)
queue.enqueue("dlq", Aptok::JsonMap{"x" => JSON::Any.new("y")})
rr = queue.process_one("dlq", pol) { |m| raise "boom" }
puts "dlq process => #{rr}, dead=#{queue.dead_messages("dlq").size}"
conn.close
puts "OK"
