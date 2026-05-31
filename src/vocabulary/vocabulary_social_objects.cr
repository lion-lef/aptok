module Aptok
  module Vocab
    class Organization < Actor
      def self.from_json_ld(value : JSON::Any) : Organization
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Organization
        new(value)
      end
    end

    class Service < Actor
      def self.from_json_ld(value : JSON::Any) : Service
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Service
        new(value)
      end
    end

    class Key < Object
      getter owner : String?
      getter controller : String?

      def self.from_json_ld(value : JSON::Any) : Key
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Key
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "CryptographicKey"
          CryptographicKey.from_json_ld(value)
        when "Multikey"
          Multikey.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @owner = self.class.string_property(json, "owner")
        @controller = self.class.string_property(json, "controller")
      end
    end

    class CryptographicKey < Key
      getter public_key_pem : String?

      def self.from_json_ld(value : JSON::Any) : CryptographicKey
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : CryptographicKey
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @public_key_pem = self.class.string_property(json, "publicKeyPem")
      end
    end

    class Multikey < Key
      getter public_key_multibase : String?

      def self.from_json_ld(value : JSON::Any) : Multikey
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Multikey
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @public_key_multibase = self.class.string_property(json, "publicKeyMultibase")
      end
    end

    class Collection < Object
      getter total_items : Int32?
      getter items : Array(Object | String)
      getter first : Object | String | Nil
      getter current : Object | String | Nil
      getter last : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : Collection
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Collection
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "OrderedCollection"
          OrderedCollection.from_json_ld(value)
        when "CollectionPage"
          CollectionPage.from_json_ld(value)
        when "OrderedCollectionPage"
          OrderedCollectionPage.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @total_items = self.class.int_property(json, "totalItems")
        @items = parse_items(json)
        @first = self.class.object_property(json, "first")
        @current = self.class.object_property(json, "current")
        @last = self.class.object_property(json, "last")
      end

      protected def parse_items(json : JsonMap) : Array(Object | String)
        self.class.object_array_property(json, "items")
      end
    end

    class OrderedCollection < Collection
      def self.from_json_ld(value : JSON::Any) : OrderedCollection
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : OrderedCollection
        new(value)
      end

      protected def parse_items(json : JsonMap) : Array(Object | String)
        items = self.class.object_array_property(json, "orderedItems")
        items.empty? ? super(json) : items
      end
    end

    class CollectionPage < Collection
      getter part_of : Object | String | Nil
      getter next : Object | String | Nil
      getter prev : Object | String | Nil

      def self.from_json_ld(value : JSON::Any) : CollectionPage
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : CollectionPage
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @part_of = self.class.object_property(json, "partOf")
        @next = self.class.object_property(json, "next")
        @prev = self.class.object_property(json, "prev")
      end
    end

    class OrderedCollectionPage < CollectionPage
      def self.from_json_ld(value : JSON::Any) : OrderedCollectionPage
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : OrderedCollectionPage
        new(value)
      end

      protected def parse_items(json : JsonMap) : Array(Object | String)
        items = self.class.object_array_property(json, "orderedItems")
        items.empty? ? super(json) : items
      end
    end

    class ForgeFedObject < Object
      getter name : String?
      getter context : String?

      def self.from_json_ld(value : JSON::Any) : ForgeFedObject
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : ForgeFedObject
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "Repository"
          Repository.from_json_ld(value)
        when "Branch"
          Branch.from_json_ld(value)
        when "Commit"
          Commit.from_json_ld(value)
        when "Push"
          Push.from_json_ld(value)
        when "Project"
          Project.from_json_ld(value)
        when "Tag"
          ForgeFedTag.from_json_ld(value)
        when "TicketTracker"
          TicketTracker.from_json_ld(value)
        when "PatchTracker"
          PatchTracker.from_json_ld(value)
        when "Ticket", "MergeRequest"
          Ticket.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @name = self.class.string_property(json, "name")
        @context = self.class.string_property(json, "context")
      end
    end

    class Project < ForgeFedObject
      getter inbox : String?
      getter outbox : String?
      getter followers : String?

      def self.from_json_ld(value : JSON::Any) : Project
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Project
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @inbox = self.class.string_property(json, "inbox")
        @outbox = self.class.string_property(json, "outbox")
        @followers = self.class.string_property(json, "followers")
      end
    end

    class Repository < ForgeFedObject
      getter inbox : String?
      getter outbox : String?
      getter clone_uri : String?
      getter push_uris : Array(String)
      getter tickets_tracked_by : String?
      getter send_patches_to : String?
      getter archived : Bool

      def self.from_json_ld(value : JSON::Any) : Repository
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Repository
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @inbox = self.class.string_property(json, "inbox")
        @outbox = self.class.string_property(json, "outbox")
        @clone_uri = self.class.string_property(json, "cloneUri")
        @push_uris = self.class.string_array_property(json, "pushUri")
        @tickets_tracked_by = self.class.string_property(json, "ticketsTrackedBy")
        @send_patches_to = self.class.string_property(json, "sendPatchesTo")
        @archived = json["isArchived"]?.try(&.as_bool?) || false
      end
    end

    class Branch < ForgeFedObject
      getter ref : String?
      getter team : String?

      def self.from_json_ld(value : JSON::Any) : Branch
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Branch
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @ref = self.class.string_property(json, "ref")
        @team = self.class.string_property(json, "team")
      end
    end
  end
end
