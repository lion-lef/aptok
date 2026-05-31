module Aptok
  module Vocab
    class Intent < MarketplaceObject
      getter action : String?
      getter resource_conforms_to : String?
      getter resource_quantity : Measure?
      getter available_quantity : Measure?
      getter minimum_quantity : Measure?

      def self.from_json_ld(value : JSON::Any) : Intent
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Intent
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @action = self.class.string_property(json, "action")
        @resource_conforms_to = self.class.string_property(json, "resourceConformsTo")
        @resource_quantity = self.class.measure_property(json, "resourceQuantity")
        @available_quantity = self.class.measure_property(json, "availableQuantity")
        @minimum_quantity = self.class.measure_property(json, "minimumQuantity")
      end
    end

    class Measure
      getter json : JsonMap
      getter unit : String?
      getter numerical_value : String?

      def self.from_json_ld(value : JSON::Any) : Measure
        map = value.as_h?
          .try(&.as(JsonMap)) ||
              raise ArgumentError.new("JSON-LD value must be an object")
        from_json_ld(map)
      end

      def self.from_json_ld(value : JsonMap) : Measure
        new(value)
      end

      def initialize(@json : JsonMap)
        @unit = self.class.string_property(@json, "hasUnit")
        @numerical_value = self.class.string_property(@json, "hasNumericalValue")
      end

      def to_json_ld : JsonMap
        @json.dup
      end

      def to_json(json : JSON::Builder) : Nil
        to_json_ld.to_json(json)
      end

      def self.string_property(value : JsonMap, key : String) : String?
        property = value[key]?
        property.try(&.as_s?) || property.try(&.as_a?).try(&.first?.try(&.as_s?))
      end
    end

    class Proposal < MarketplaceObject
      getter purpose : String?
      getter attributed_to : String?
      getter content : String?
      getter publishes : Object | String | Nil
      getter reciprocal : Object | String | Nil
      getter unit_based : Bool?
      getter to : Array(String)
      getter location : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : Proposal
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Proposal
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @purpose = self.class.string_property(json, "purpose")
        @attributed_to = self.class.string_property(json, "attributedTo")
        @content = self.class.string_property(json, "content")
        @publishes = self.class.object_property(json, "publishes")
        @reciprocal = self.class.object_property(json, "reciprocal")
        @unit_based = self.class.bool_property(json, "unitBased")
        @to = self.class.string_array_property(json, "to")
        @location = self.class.object_property(json, "location")
      end
    end

    class Commitment < MarketplaceObject
      getter satisfies : String?
      getter resource_quantity : JsonMap?

      def self.from_json_ld(value : JSON::Any) : Commitment
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Commitment
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @satisfies = self.class.string_property(json, "satisfies")
        @resource_quantity = self.class.map_property(json, "resourceQuantity")
      end
    end

    class Agreement < MarketplaceObject
      getter attributed_to : String?
      getter stipulates : Object | String | Nil
      getter stipulates_reciprocal : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : Agreement
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Agreement
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @attributed_to = self.class.string_property(json, "attributedTo")
        @stipulates = self.class.object_property(json, "stipulates")
        @stipulates_reciprocal = self.class.object_property(json, "stipulatesReciprocal")
      end
    end
  end

  def self.json(value) : JSON::Any
    JSON.parse(value.to_json)
  end

  def self.now : String
    Time.utc.to_s("%Y-%m-%dT%H:%M:%SZ")
  end

  def self.object(type : String, id : String? = nil, properties : JsonMap = JsonMap.new) : JsonMap
    map = JsonMap{
      "@context" => json(ACTIVITYSTREAMS_CONTEXT),
      "type"     => json(type),
    }
    map["id"] = json(id) if id
    properties.each { |key, value| map[key] = value }
    map
  end

  def self.actor(
    type : String,
    id : String,
    preferred_username : String,
    inbox : String,
    outbox : String,
    name : String? = nil,
    summary : String? = nil,
    followers : String? = nil,
    following : String? = nil,
    liked : String? = nil,
    featured : String? = nil,
    featured_tags : String? = nil,
    streams : Array(String) = [] of String,
    manually_approves_followers : Bool? = nil,
    discoverable : Bool? = nil,
    suspended : Bool? = nil,
    memorial : Bool? = nil,
    indexable : Bool? = nil,
    successor : String? = nil,
    alias_uri : String? = nil,
    shared_inbox : String? = nil,
    oauth_authorization_endpoint : String? = nil,
    oauth_token_endpoint : String? = nil,
    provide_client_key : String? = nil,
    sign_client_key : String? = nil,
    upload_media : String? = nil,
    proxy_url : String? = nil,
    public_key : JsonMap? = nil,
    assertion_methods : Array(JsonMap) = [] of JsonMap,
    gateways : Array(String) = [] of String
  ) : JsonMap
    properties = JsonMap{
      "preferredUsername" => json(preferred_username),
      "inbox"             => json(inbox),
      "outbox"            => json(outbox),
    }
    properties["name"] = json(name) if name
    properties["summary"] = json(summary) if summary
    properties["followers"] = json(followers) if followers
    properties["following"] = json(following) if following
    properties["liked"] = json(liked) if liked
    properties["featured"] = json(featured) if featured
    properties["featuredTags"] = json(featured_tags) if featured_tags
    properties["streams"] = json(streams) unless streams.empty?
    properties["manuallyApprovesFollowers"] = json(manually_approves_followers) unless manually_approves_followers.nil?
    properties["discoverable"] = json(discoverable) unless discoverable.nil?
    properties["suspended"] = json(suspended) unless suspended.nil?
    properties["memorial"] = json(memorial) unless memorial.nil?
    properties["indexable"] = json(indexable) unless indexable.nil?
    properties["successor"] = json(successor) if successor
    properties["alsoKnownAs"] = json(alias_uri) if alias_uri
    endpoints = JsonMap.new
    endpoints["sharedInbox"] = json(shared_inbox) if shared_inbox
    endpoints["oauthAuthorizationEndpoint"] = json(oauth_authorization_endpoint) if oauth_authorization_endpoint
    endpoints["oauthTokenEndpoint"] = json(oauth_token_endpoint) if oauth_token_endpoint
    endpoints["provideClientKey"] = json(provide_client_key) if provide_client_key
    endpoints["signClientKey"] = json(sign_client_key) if sign_client_key
    endpoints["uploadMedia"] = json(upload_media) if upload_media
    endpoints["proxyUrl"] = json(proxy_url) if proxy_url
    properties["endpoints"] = json(endpoints) unless endpoints.empty?
    properties["publicKey"] = json(public_key) if public_key
    properties["assertionMethod"] = json(assertion_methods) unless assertion_methods.empty?
    unless gateways.empty?
      properties["@context"] = json([ACTIVITYSTREAMS_CONTEXT, FEP_EF61_CONTEXT])
      properties["gateways"] = json(gateways)
    end
    Aptok.object(type, id, properties)
  end

  def self.public_key(id : String, owner : String, public_key_pem : String) : JsonMap
    JsonMap{
      "type"         => json("CryptographicKey"),
      "id"           => json(id),
      "owner"        => json(owner),
      "publicKeyPem" => json(public_key_pem),
    }
  end

  def self.multikey(id : String, controller : String, public_key_multibase : String) : JsonMap
    JsonMap{
      "@context"           => json(MULTIKEY_CONTEXT),
      "id"                 => json(id),
      "type"               => json("Multikey"),
      "controller"         => json(controller),
      "publicKeyMultibase" => json(public_key_multibase),
    }
  end

  def self.note(
    id : String,
    content : String,
    name : String? = nil,
    attributed_to : String? = nil,
    to : Array(String) = [PUBLIC_COLLECTION]
  ) : JsonMap
    properties = JsonMap{
      "content"   => json(content),
      "published" => json(now),
      "to"        => json(to),
    }
    properties["name"] = json(name) if name
    properties["attributedTo"] = json(attributed_to) if attributed_to
    Aptok.object("Note", id, properties)
  end
end
