module Aptok
  module Vocab
    class MarketplaceObject < Object
      getter name : String?

      def self.from_json_ld(value : JSON::Any) : MarketplaceObject
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : MarketplaceObject
        type = string_property(value, "type").try { |value| Aptok.type_name(value) }
        case type
        when "Offer"
          MarketplaceOffer.from_json_ld(value)
        when "Product"
          Product.from_json_ld(value)
        when "Service"
          MarketplaceService.from_json_ld(value)
        when "PriceSpecification"
          PriceSpecification.from_json_ld(value)
        when "Listing"
          Listing.from_json_ld(value)
        when "Intent"
          Intent.from_json_ld(value)
        when "Proposal"
          Proposal.from_json_ld(value)
        when "Commitment"
          Commitment.from_json_ld(value)
        when "Agreement"
          Agreement.from_json_ld(value)
        else
          new(value)
        end
      end

      def initialize(json : JsonMap)
        super(json)
        @name = self.class.string_property(json, "name")
      end
    end

    class MarketplaceOffer < MarketplaceObject
      getter actor : String?
      getter item : Object | String | Nil
      getter object : Object | String | Nil
      getter price : String?
      getter price_currency : String?

      def self.type_name : String
        "Offer"
      end

      def self.from_json_ld(value : JSON::Any) : MarketplaceOffer
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : MarketplaceOffer
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @actor = self.class.string_property(json, "actor")
        @item = self.class.object_property(json, "item")
        @object = self.class.object_property(json, "object")
        @price = self.class.string_property(json, "price")
        @price_currency = self.class.string_property(json, "priceCurrency")
      end
    end

    class Product < MarketplaceObject
      getter summary : String?
      getter attributed_to : String?

      def self.from_json_ld(value : JSON::Any) : Product
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Product
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @summary = self.class.string_property(json, "summary")
        @attributed_to = self.class.string_property(json, "attributedTo")
      end
    end

    class MarketplaceService < MarketplaceObject
      getter summary : String?
      getter attributed_to : String?
      getter provider : Object | String | Nil
      getter terms_of_service : String?

      def self.type_name : String
        "Service"
      end

      def self.from_json_ld(value : JSON::Any) : MarketplaceService
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : MarketplaceService
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @summary = self.class.string_property(json, "summary")
        @attributed_to = self.class.string_property(json, "attributedTo")
        @provider = self.class.object_property(json, "provider")
        @terms_of_service = self.class.string_property(json, "termsOfService")
      end
    end

    class PriceSpecification < MarketplaceObject
      getter price : String?
      getter price_currency : String?
      getter unit_text : String?

      def self.from_json_ld(value : JSON::Any) : PriceSpecification
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : PriceSpecification
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @price = self.class.string_property(json, "price")
        @price_currency = self.class.string_property(json, "priceCurrency")
        @unit_text = self.class.string_property(json, "unitText")
      end
    end

    class Listing < MarketplaceObject
      getter actor : String?
      getter item : Object | String | Nil
      getter price_specification : Object | String | Nil
      getter to : Array(String)

      def self.from_json_ld(value : JSON::Any) : Listing
        from_json_ld(json_object(value))
      end

      def self.from_json_ld(value : JsonMap) : Listing
        new(value)
      end

      def initialize(json : JsonMap)
        super(json)
        @actor = self.class.string_property(json, "actor")
        @item = self.class.object_property(json, "item")
        @price_specification = self.class.object_property(json, "priceSpecification")
        @to = self.class.string_array_property(json, "to")
      end
    end
  end
end
