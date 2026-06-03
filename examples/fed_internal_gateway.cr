require "http/server"
require "../src/aptok"

private_domain = ENV["APTOK_PRIVATE_DOMAIN"]? || "fed.internal"
origin = ENV["APTOK_GATEWAY_ORIGIN"]? || "http://gateway.#{private_domain}:3000"
upstream = ENV["APTOK_PRIVATE_UPSTREAM"]? || "http://127.0.0.1:4010"
port = (ENV["PORT"]? || "3000").to_i

def csv_env(name : String) : Array(String)
  value = ENV[name]? || ""
  value.split(",").map(&.strip).reject(&.empty?)
end

def activity_actor_id(activity : Aptok::JsonMap) : String?
  value = activity["actor"]?
  return nil unless value

  if string = value.as_s?
    return string unless string.empty?
  elsif object = value.as_h?
    return object["id"]?.try(&.as_s?)
  elsif array = value.as_a?
    array.each do |item|
      if id = activity_actor_id(Aptok::JsonMap{"actor" => item})
        return id
      end
    end
  end

  nil
end

store = Aptok::MemoryKvStore.new
acl = Aptok::PrivateGateway::AccessList.new(
  host_suffixes: [private_domain],
  actor_ids: csv_env("APTOK_ALLOWED_ACTORS"),
  blocked_actor_ids: csv_env("APTOK_BLOCKED_ACTORS")
)
resolver = Aptok::PrivateGateway::LocalNameResolver.new(
  {
    private_domain        => upstream,
    "*.#{private_domain}" => upstream,
  },
  private_domain
)
loader = Aptok::PrivateGateway.document_loader(
  Aptok::PrivateGateway::Config.new(resolver, acl, store)
)
actor_cache = Aptok::PrivateGateway::ActorCache.new(store)

federation = Aptok.federation(
  origin,
  document_loader: loader,
  kv: store,
  allow_private_address: true
) do
  signature_keys Aptok::PrivateGateway.signature_key_resolver(loader, acl, store)
  inbox_signature_verification
  authorize_actor Aptok::PrivateGateway.authorize_signed_fetch(acl)

  actor "/gateway/{identifier}" do |ctx, identifier|
    Aptok.actor(
      "Service",
      ctx.get_actor_uri(identifier),
      identifier,
      ctx.get_inbox_uri(identifier),
      ctx.get_outbox_uri(identifier),
      name: "#{private_domain} ActivityPub gateway",
      shared_inbox: ctx.get_inbox_uri
    ).as(Aptok::JsonMap?)
  end

  inbox "/gateway/{identifier}/inbox", "/inbox" do |routes|
    routes.on "Activity" do |ctx, activity|
      if actor_id = activity_actor_id(activity)
        if acl.allows_actor?(actor_id)
          actor_cache.fetch(actor_id, ctx.document_loader)
        else
          puts "ignored activity from blocked actor #{actor_id}"
        end
      end
      nil
    end
  end
end

not_found = Aptok::Response.new(404, {"Content-Type" => "text/plain"}, "Not found")
not_acceptable = Aptok::Response.new(
  406,
  {"Content-Type" => Aptok::FEDIFY_TEXT_CONTENT_TYPE, "Vary" => "Accept, Signature"},
  "Not Acceptable"
)
forbidden = Aptok::Response.new(403, {"Content-Type" => "text/plain"}, "forbidden")
fetch_options = Aptok::FetchOptions.new(
  on_not_found: Aptok::RequestHandler.new { |_request| not_found },
  on_not_acceptable: Aptok::RequestHandler.new { |_request| not_acceptable },
  on_unauthorized: Aptok::RequestHandler.new { |_request| forbidden }
)

server = HTTP::Server.new do |context|
  request = Aptok.request_from_http(context.request)
  response = federation.fetch(request, fetch_options)
  Aptok.write_http_response(response, context.response)
end

address = server.bind_tcp("127.0.0.1", port)
puts "Listening on http://#{address}"
puts "Resolving *.#{private_domain} through #{upstream}"
server.listen
