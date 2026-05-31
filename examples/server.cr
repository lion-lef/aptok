require "http/server"
require "../src/aptok"

origin = ENV["APTOK_ORIGIN"]? || "http://localhost:3000"

federation = Aptok.federation(origin) do
  actor "/users/{identifier}" do |ctx, identifier|
    Aptok.actor(
      "Person",
      ctx.get_actor_uri(identifier),
      identifier,
      ctx.get_inbox_uri(identifier),
      ctx.get_outbox_uri(identifier),
      name: identifier.capitalize,
      shared_inbox: "#{ctx.origin}/inbox",
      followers: ctx.get_followers_uri(identifier),
      following: ctx.get_following_uri(identifier)
    ).as(Aptok::JsonMap?)
  end

  set_outbox_dispatcher "/users/{identifier}/outbox", ->(ctx : Aptok::Context, identifier : String) do
    note = Aptok.object(
      "Note",
      "#{ctx.get_outbox_uri(identifier)}/hello",
      Aptok::JsonMap{
        "attributedTo" => Aptok.json(ctx.get_actor_uri(identifier)),
        "content"      => Aptok.json("Hello from Aptok"),
        "to"           => Aptok.json([Aptok::PUBLIC_COLLECTION]),
      }
    )

    [Aptok.create(
      "#{ctx.get_outbox_uri(identifier)}/hello/activity",
      ctx.get_actor_uri(identifier),
      note
    )]
  end

  inbox "/users/{identifier}/inbox", "/inbox" do |routes|
    routes.on "Create" do |ctx, activity|
      actor = activity["actor"]?.try(&.as_s?)
      puts "received Create for #{ctx.recipient_identifier || "shared inbox"} from #{actor || "unknown actor"}"
    end
  end
end

server = HTTP::Server.new do |context|
  request = Aptok.request_from_http(context.request)
  response = federation.fetch(
    request,
    on_not_found: ->(_request : Aptok::Request) {
      Aptok::Response.new(404, {"Content-Type" => "text/plain"}, "Not found")
    },
    on_not_acceptable: ->(_request : Aptok::Request) {
      Aptok::Response.new(
        406,
        {"Content-Type" => Aptok::FEDIFY_TEXT_CONTENT_TYPE, "Vary" => "Accept, Signature"},
        "Not Acceptable"
      )
    }
  )
  Aptok.write_http_response(response, context.response)
end

address = server.bind_tcp("127.0.0.1", 3000)
puts "Listening on http://#{address}"
server.listen
