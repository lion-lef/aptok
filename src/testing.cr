require "./federation/federation"
require "uri"

module Aptok
  class CaptureTransport < Transport
    record Delivery, delivery_config : DeliveryConfig, activity : JsonMap, payload : String

    getter deliveries : Array(Delivery)

    def initialize
      @deliveries = [] of Delivery
      super(signature_enabled: false)
    end

    def deliver!(delivery : DeliveryConfig, activity : JsonMap, key_pair : ActorKeyPair? = nil) : String
      @deliveries << Delivery.new(delivery, activity, activity.to_json)
      activity["id"]?.try(&.as_s?) || ""
    end
  end

  module Testing
    def self.generate_rsa_key_pair(owner : String, key_id : String? = nil) : ActorKeyPair
      private_key = openssl_output("genrsa", ["genrsa", "512"])
      public_key = openssl_output("rsa -pubout", ["rsa", "-pubout"], private_key)

      ActorKeyPair.new(
        id: key_id || "#{owner}#main-key",
        owner: owner,
        public_key_pem: public_key,
        private_key_pem: private_key
      )
    end

    def self.generate_ed25519_key_pair(owner : String, key_id : String? = nil) : ActorKeyPair
      private_key = openssl_output("genpkey Ed25519", ["genpkey", "-algorithm", "Ed25519"])
      public_key = openssl_output("pkey -pubout", ["pkey", "-pubout"], private_key)

      ActorKeyPair.new(
        id: key_id || "#{owner}#multikey-1",
        owner: owner,
        public_key_pem: public_key,
        private_key_pem: private_key,
        algorithm: "ed25519"
      )
    end

    def self.create_federation(origin : String = "https://example.com") : Federation
      Federation.create(origin, CaptureTransport.new)
    end

    def self.create_context(origin : String = "https://example.com") : Context
      create_federation(origin).create_context
    end

    def self.create_context(
      federation : Federation,
      request : Request? = nil,
      recipient_identifier : String? = nil,
      outbox_identifier : String? = nil,
      context_data : JSON::Any? = nil,
      document_loader : DocumentLoader? = nil,
      context_loader : DocumentLoader? = nil
    ) : Context
      ctx = federation.create_context(context_data: context_data)
      ctx = ctx.with_inbound_request(request) if request
      ctx = ctx.with_recipient(recipient_identifier) unless recipient_identifier.nil?
      ctx = ctx.with_outbox(outbox_identifier) unless outbox_identifier.nil?
      ctx = ctx.with_document_loader(document_loader) if document_loader
      ctx = ctx.with_context_loader(context_loader) if context_loader
      ctx
    end

    def self.create_request_context(
      federation : Federation,
      request : Request = Request.new("GET", "/"),
      context_data : JSON::Any? = nil,
      document_loader : DocumentLoader? = nil,
      context_loader : DocumentLoader? = nil
    ) : Context
      create_context(
        federation,
        request,
        context_data: context_data,
        document_loader: document_loader,
        context_loader: context_loader
      )
    end

    def self.create_inbox_context(
      federation : Federation,
      identifier : String? = nil,
      request : Request? = nil,
      context_data : JSON::Any? = nil,
      document_loader : DocumentLoader? = nil,
      context_loader : DocumentLoader? = nil
    ) : Context
      ctx = federation.create_context
      request ||= if identifier
                    Request.new(
                      "POST",
                      URI.parse(ctx.get_inbox_uri(identifier)).path,
                      headers: {"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE}
                    )
                  else
                    Request.new(
                      "POST",
                      URI.parse(ctx.get_inbox_uri).path,
                      headers: {"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE}
                    )
                  end
      create_context(
        federation,
        request,
        recipient_identifier: identifier,
        context_data: context_data,
        document_loader: document_loader,
        context_loader: context_loader
      )
    end

    def self.create_outbox_context(
      federation : Federation,
      identifier : String,
      request : Request? = nil,
      context_data : JSON::Any? = nil,
      document_loader : DocumentLoader? = nil,
      context_loader : DocumentLoader? = nil
    ) : Context
      ctx = federation.create_context
      request ||= Request.new(
        "POST",
        URI.parse(ctx.get_outbox_uri(identifier)).path,
        headers: {"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE}
      )
      create_context(
        federation,
        request,
        outbox_identifier: identifier,
        context_data: context_data,
        document_loader: document_loader,
        context_loader: context_loader
      )
    end

    def self.post_inbox_activity(
      federation : Federation,
      activity : JsonMap,
      identifier : String? = nil,
      headers : Hash(String, String) = {"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE},
      context_data : JSON::Any? = nil
    ) : Response
      ctx = federation.create_context
      path = if identifier
               URI.parse(ctx.get_inbox_uri(identifier)).path
             else
               URI.parse(ctx.get_inbox_uri).path
             end
      federation.handle(Request.new(
        "POST",
        path,
        headers: headers,
        body: activity.to_json
      ), context_data: context_data)
    end

    def self.receive_activity(
      federation : Federation,
      activity : JsonMap,
      identifier : String? = nil,
      headers : Hash(String, String) = {"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE},
      context_data : JSON::Any? = nil
    ) : Response
      post_inbox_activity(federation, activity, identifier, headers, context_data)
    end

    def self.post_outbox_activity(
      federation : Federation,
      identifier : String,
      activity : JsonMap,
      headers : Hash(String, String) = {"Content-Type" => FEDERATION_JSONLD_CONTENT_TYPE},
      context_data : JSON::Any? = nil
    ) : Response
      ctx = federation.create_context
      federation.handle(Request.new(
        "POST",
        URI.parse(ctx.get_outbox_uri(identifier)).path,
        headers: headers,
        body: activity.to_json
      ), context_data: context_data)
    end

    private def self.openssl_output(command : String, args : Array(String), input : String? = nil) : String
      output = IO::Memory.new
      errors = IO::Memory.new
      status = if input
                 Process.run(
                   "openssl",
                   args: args,
                   input: IO::Memory.new(input),
                   output: output,
                   error: errors
                 )
               else
                 Process.run(
                   "openssl",
                   args: args,
                   output: output,
                   error: errors
                 )
               end
      raise "openssl #{command} failed: #{errors.to_s}" unless status.success?

      output.to_s
    end
  end
end
