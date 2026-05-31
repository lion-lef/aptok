require "../src/aptork"
require "../src/store/sqlite"

conn = Aptork::SqliteConnection.open(":memory:")
store = Aptork::SqlKvStore.new(conn, dialect: Aptork::SqlDialect::Sqlite)

store.set("actor:alice", "{\"name\":\"Alice\"}")
puts "get => #{store.get("actor:alice").inspect}"
puts "cas (nil->v) on existing => #{store.cas("actor:alice", nil, "X")}"  # false
puts "cas (match) => #{store.cas("actor:alice", "{\"name\":\"Alice\"}", "{\"name\":\"Alice2\"}")}" # true
puts "get => #{store.get("actor:alice").inspect}"
store.set("actor:bob", "b")
store.set("object:1", "o")
puts "list prefix actor: => #{store.list("actor:").map(&.key)}"

# ttl
store.set("temp", "v", ttl: 10.milliseconds)
puts "temp present => #{store.get("temp").inspect}"
sleep 30.milliseconds
puts "temp expired => #{store.get("temp").inspect}"

queue = Aptork::SqlMessageQueue.new(conn, dialect: Aptork::SqlDialect::Sqlite)
queue.enqueue("inbox", Aptork::JsonMap{"a" => JSON::Any.new("1")})
queue.enqueue("inbox", Aptork::JsonMap{"a" => JSON::Any.new("2")})
puts "depth => #{queue.depth("inbox")}"
processed = [] of String
res = queue.process_one("inbox") { |m| processed << m.payload["a"].as_s }
puts "process_one => #{res}, payload=#{processed}"
puts "depth after => #{queue.depth("inbox")}"

# retry/dead
fail_q = Aptork::SqlMessageQueue.new(conn, dialect: Aptork::SqlDialect::Sqlite, table: "q2")
fail_q.enqueue("d", Aptork::JsonMap{"x" => JSON::Any.new("y")})
policy = Aptork::RetryPolicy.new(max_attempts: 1)
r = fail_q.process_one("d", policy) { |m| raise "boom" }
puts "fail process_one => #{r}"
puts "dead => #{fail_q.dead_messages("d").size}"
