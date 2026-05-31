require "json"
require "uri"

module Aptok
  alias JsonMap = Hash(String, JSON::Any)

  VERSION                          = "0.1.0"
  ACTIVITYSTREAMS_CONTEXT          = "https://www.w3.org/ns/activitystreams"
  FEDERATION_JSONLD_CONTEXT        = ACTIVITYSTREAMS_CONTEXT
  FEDERATION_JSONLD_CONTENT_TYPE   = "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""
  FEDERATION_ACTIVITY_CONTENT_TYPE = "application/activity+json"
  PUBLIC_COLLECTION                = "https://www.w3.org/ns/activitystreams#Public"

  ACTOR_TYPES  = %w[Application Group Organization Person Service]
  OBJECT_TYPES = %w[
    Article Audio Document Event Image Note Page Place Profile Relationship Tombstone Video
  ]
  ACTIVITY_TYPES = %w[
    Accept Add Announce Arrive Block Create Delete Dislike Flag Follow Ignore Invite Join
    Leave Like Listen Move Offer Question Reject Read Remove TentativeAccept TentativeReject IntransitiveActivity
    Travel Undo Update View
  ]

  FORGEFED_CONTEXT = "https://forgefed.org/ns"
  FORGEFED_TYPES   = %w[
    Repository Ticket MergeRequest Commit Branch Tag Push Project TicketTracker PatchTracker
    TicketDependency
  ]
  FORGEFED_ACTIVITY_TYPES = %w[
    Resolve Apply Grant Revoke
  ]

  MARKETPLACE_CONTEXT = "https://w3id.org/fep/0837"
  VALUEFLOWS_CONTEXT  = "https://w3id.org/valueflows/ont/vf#"
  OM2_CONTEXT         = "http://www.ontology-of-units-of-measure.org/resource/om-2/"
  SECURITY_CONTEXT    = "https://w3id.org/security/v1"
  MULTIKEY_CONTEXT    = "https://w3id.org/security/multikey/v1"
  MASTODON_CONTEXT    = "http://joinmastodon.org/ns#"
  SCHEMA_CONTEXT      = "http://schema.org#"
  FEDIBIRD_CONTEXT    = "http://fedibird.com/ns#"
  FEP_044F_CONTEXT    = "https://w3id.org/fep/044f#"
  MARKETPLACE_TYPES   = %w[
    Offer Product Service Listing PriceSpecification Proposal Intent Agreement Commitment Measure
  ]
  KEY_TYPES = %w[CryptographicKey Multikey]

  def self.type_name(type : String) : String
    indexes = [] of Int32
    indexes << type.rindex('#').not_nil! if type.rindex('#')
    indexes << type.rindex('/').not_nil! if type.rindex('/')
    index = indexes.max?
    index ? type[(index + 1)..] : type
  end

  def self.type_id(type : String) : String
    name = type_name(type)
    if ACTOR_TYPES.includes?(name) || OBJECT_TYPES.includes?(name) || ACTIVITY_TYPES.includes?(name) || name.in?("Link", "Mention", "Hashtag", "Collection", "OrderedCollection", "CollectionPage", "OrderedCollectionPage")
      "#{ACTIVITYSTREAMS_CONTEXT}##{name}"
    elsif name == "Emoji"
      "#{MASTODON_CONTEXT}Emoji"
    elsif name == "PropertyValue"
      "#{SCHEMA_CONTEXT}PropertyValue"
    elsif FORGEFED_TYPES.includes?(name) || FORGEFED_ACTIVITY_TYPES.includes?(name)
      "#{FORGEFED_CONTEXT}##{name}"
    elsif name.in?("Intent", "Measure", "Proposal", "Commitment", "Agreement")
      "#{VALUEFLOWS_CONTEXT}#{name}"
    elsif MARKETPLACE_TYPES.includes?(name)
      "#{MARKETPLACE_CONTEXT}##{name}"
    elsif name == "CryptographicKey"
      "#{SECURITY_CONTEXT}#CryptographicKey"
    elsif name == "Multikey"
      "#{MULTIKEY_CONTEXT}#Multikey"
    else
      name
    end
  end

  def self.type_lineage(type : String) : Array(String)
    name = type_name(type)
    ancestors = case name
                when "Invite"
                  ["Offer"]
                when "TentativeAccept"
                  ["Accept"]
                when "TentativeReject"
                  ["Reject"]
                when "Block"
                  ["Ignore"]
                when .in?("Repository", "Branch", "Commit", "Push", "Ticket", "MergeRequest")
                  ["ForgeFedObject"]
                when "TicketDependency"
                  ["Relationship"]
                when .in?("Resolve", "Apply", "Grant", "Revoke")
                  ["ForgeFedActivity"]
                when .in?("Offer", "Product", "PriceSpecification", "Listing", "Intent", "Measure", "Proposal", "Commitment", "Agreement")
                  ["MarketplaceObject"]
                when .in?("CryptographicKey", "Multikey")
                  ["Key"]
                when .in?("Mention", "Hashtag")
                  ["Link"]
                when .in?("Arrive", "Question", "Travel")
                  ["IntransitiveActivity"]
                else
                  [] of String
                end
    ancestors << "Activity" if ACTIVITY_TYPES.includes?(name) || FORGEFED_ACTIVITY_TYPES.includes?(name)
    ([name] + ancestors).uniq
  end
end
