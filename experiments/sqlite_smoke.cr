require "../src/aptok"
require "../src/store/sqlite"

conn = Aptok::SqliteConnection.open(":memory:")
store = Aptok::SqlKvStore.new(conn)

store.set("actor:alice", "{\"name\":\"Alice\"}")
puts "get => #{store.get("actor:alice").inspect}"
puts "cas (nil->v) on existing => #{store.cas("actor:alice", nil, "X")}"                           # false
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

queue = Aptok::SqlMessageQueue.new(conn)
queue.enqueue("inbox", Aptok::JsonMap{"a" => JSON::Any.new("1")})
queue.enqueue("inbox", Aptok::JsonMap{"a" => JSON::Any.new("2")})
puts "depth => #{queue.depth("inbox")}"
processed = [] of String
res = queue.process_one("inbox") { |m| processed << m.payload["a"].as_s }
puts "process_one => #{res}, payload=#{processed}"
puts "depth after => #{queue.depth("inbox")}"

# retry/dead
fail_q = Aptok::SqlMessageQueue.new(conn, table: "q2")
fail_q.enqueue("d", Aptok::JsonMap{"x" => JSON::Any.new("y")})
policy = Aptok::RetryPolicy.new(max_attempts: 1)
r = fail_q.process_one("d", policy) { |m| raise "boom" }
puts "fail process_one => #{r}"
puts "dead => #{fail_q.dead_messages("d").size}"
