module Aptok
  module Vocab
    class PropertyValue < Object
      getter name : String?
      getter value : String?

      def self.from_json_ld(value : JSON::Any) : PropertyValue
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : PropertyValue
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @name = self.class.string_property(json, "name")
        @value = self.class.string_property(json, "value")
      end
    end

    class Link < Object
      getter href : String?
      getter rel : Array(String)
      getter media_type : String?
      getter name : String?
      getter hreflang : String?
      getter height : Int32?
      getter width : Int32?

      def self.from_json_ld(value : JSON::Any) : Link
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Link
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "Mention"
          Mention.from_json_ld(value)
        when "Hashtag"
          Hashtag.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @href = self.class.string_property(json, "href")
        @rel = self.class.string_array_property(json, "rel")
        @media_type = self.class.string_property(json, "mediaType")
        @name = self.class.string_property(json, "name")
        @hreflang = self.class.string_property(json, "hreflang")
        @height = self.class.int_property(json, "height")
        @width = self.class.int_property(json, "width")
      end
    end

    class Mention < Link
      def self.from_json_ld(value : JSON::Any) : Mention
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Mention
        new(value)
      end
    end

    class Hashtag < Link
      def self.from_json_ld(value : JSON::Any) : Hashtag
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Hashtag
        new(value)
      end
    end

    class Emoji < StandardObject
      getter icon : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : Emoji
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Emoji
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @icon = self.class.object_property(json, "icon")
      end
    end

    class Note < StandardObject
      def self.from_json_ld(value : JSON::Any) : Note
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Note
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
      end
    end

    class Tombstone < Object
      getter former_types : Array(String)
      getter deleted : String?

      def self.from_json_ld(value : JSON::Any) : Tombstone
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Tombstone
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @former_types = self.class.string_array_property(json, "formerType")
        @deleted = self.class.string_property(json, "deleted")
      end

      def former_type : String?
        @former_types.first?
      end
    end

    class Actor < Object
      getter preferred_username : String?
      getter inbox : String?
      getter outbox : String?
      getter followers : String?
      getter following : String?
      getter liked : String?
      getter featured : String?
      getter featured_tags : String?
      getter streams : Array(Object | String)
      getter endpoints : Endpoints?
      getter shared_inbox : String?
      getter public_key : Object | String | Nil
      getter assertion_methods : Array(Object | String)
      getter gateways : Array(String)
      getter manually_approves_followers : Bool?
      getter discoverable : Bool?
      getter suspended : Bool?
      getter memorial : Bool?
      getter indexable : Bool?
      getter successor : Object | String | Nil
      getter also_known_as : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : Actor
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Actor
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "Application"
          Application.from_json_ld(value)
        when "Group"
          Group.from_json_ld(value)
        when "Organization"
          Organization.from_json_ld(value)
        when "Person"
          Person.from_json_ld(value)
        when "Service"
          Service.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @preferred_username = self.class.string_property(json, "preferredUsername")
        @inbox = self.class.string_property(json, "inbox")
        @outbox = self.class.string_property(json, "outbox")
        @followers = self.class.string_property(json, "followers")
        @following = self.class.string_property(json, "following")
        @liked = self.class.string_property(json, "liked")
        @featured = self.class.string_property(json, "featured")
        @featured_tags = self.class.string_property(json, "featuredTags")
        @streams = self.class.object_array_property(json, "streams")
        @endpoints = self.class.endpoints_property(json)
        @shared_inbox = self.class.shared_inbox_property(json)
        @public_key = self.class.object_property(json, "publicKey")
        @assertion_methods = self.class.object_array_property(json, "assertionMethod")
        @assertion_methods = self.class.object_array_property(json, "assertionMethods") if @assertion_methods.empty?
        @gateways = self.class.string_array_property(json, "gateways")
        @manually_approves_followers = self.class.bool_property(json, "manuallyApprovesFollowers")
        @discoverable = self.class.bool_property(json, "discoverable")
        @suspended = self.class.bool_property(json, "suspended")
        @memorial = self.class.bool_property(json, "memorial")
        @indexable = self.class.bool_property(json, "indexable")
        @successor = self.class.object_property(json, "successor")
        @also_known_as = self.class.object_property(json, "alias") || self.class.object_property(json, "alsoKnownAs")
      end

      protected def self.shared_inbox_property(value : JsonMap) : String?
        endpoints = endpoints_property(value)
        endpoints.try(&.shared_inbox)
      end

      protected def self.endpoints_property(value : JsonMap) : Endpoints?
        map_property(value, "endpoints").try { |endpoints| Endpoints.from_json_ld(endpoints) }
      end
    end

    class Endpoints
      getter json : JsonMap
      getter shared_inbox : String?
      getter oauth_authorization_endpoint : String?
      getter oauth_token_endpoint : String?
      getter provide_client_key : String?
      getter sign_client_key : String?
      getter upload_media : String?
      getter proxy_url : String?

      def self.from_json_ld(value : JSON::Any) : Endpoints
        from_json_ld(value.as_h?.try(&.as(JsonMap)) || raise ArgumentError.new("JSON-LD endpoints must be an object"))
      end

      def self.from_json_ld(value : JsonMap) : Endpoints
        new(value)
      end

      def initialize(@json : JsonMap)
        @shared_inbox = self.class.string_property(@json, "sharedInbox")
        @oauth_authorization_endpoint = self.class.string_property(@json, "oauthAuthorizationEndpoint")
        @oauth_token_endpoint = self.class.string_property(@json, "oauthTokenEndpoint")
        @provide_client_key = self.class.string_property(@json, "provideClientKey")
        @sign_client_key = self.class.string_property(@json, "signClientKey")
        @upload_media = self.class.string_property(@json, "uploadMedia")
        @proxy_url = self.class.string_property(@json, "proxyUrl")
      end

      def to_json_ld : JsonMap
        @json.dup
      end

      def self.string_property(value : JsonMap, key : String) : String?
        property = value[key]?
        property.try(&.as_s?) || property.try(&.as_a?).try(&.first?.try(&.as_s?))
      end
    end

    class Person < Actor
      def self.from_json_ld(value : JSON::Any) : Person
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Person
        new(value)
      end
    end

    class Application < Actor
      def self.from_json_ld(value : JSON::Any) : Application
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Application
        new(value)
      end
    end

    class Group < Actor
      def self.from_json_ld(value : JSON::Any) : Group
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Group
        new(value)
      end
    end
  end
end
