module Aptok
  def self.standard_object(
    type : String,
    id : String,
    name : String? = nil,
    summary : String? = nil,
    content : String? = nil,
    media_type : String? = nil,
    url : JsonMap | String | Nil = nil,
    attributed_to : String? = nil,
    attachments : Array(JsonMap | String) = [] of JsonMap | String,
    tags : Array(JsonMap | String) = [] of JsonMap | String,
    published : String? = nil,
    updated : String? = nil,
    sensitive : Bool? = nil,
    source_content : String? = nil,
    source_media_type : String? = nil
  ) : JsonMap
    properties = JsonMap.new
    properties["name"] = json(name) if name
    properties["summary"] = json(summary) if summary
    properties["content"] = json(content) if content
    properties["mediaType"] = json(media_type) if media_type
    properties["url"] = json(url) if url
    properties["attributedTo"] = json(attributed_to) if attributed_to
    properties["attachment"] = json(attachments) unless attachments.empty?
    properties["tag"] = json(tags) unless tags.empty?
    properties["published"] = json(published || now)
    properties["updated"] = json(updated) if updated
    properties["sensitive"] = json(sensitive) unless sensitive.nil?
    if source_content || source_media_type
      source = JsonMap.new
      source["content"] = json(source_content) if source_content
      source["mediaType"] = json(source_media_type) if source_media_type
      properties["source"] = json(source)
    end
    Aptok.object(type, id, properties)
  end

  macro standard_object_builder(method_name, type_name)
    def self.{{method_name.id}}(
      id : String,
      name : String? = nil,
      summary : String? = nil,
      content : String? = nil,
      media_type : String? = nil,
      url : JsonMap | String | Nil = nil,
      attributed_to : String? = nil,
      attachments : Array(JsonMap | String) = [] of JsonMap | String,
      tags : Array(JsonMap | String) = [] of JsonMap | String,
      published : String? = nil,
      updated : String? = nil,
      sensitive : Bool? = nil,
      source_content : String? = nil,
      source_media_type : String? = nil,
    ) : JsonMap
      standard_object(
        {{type_name}},
        id,
        name,
        summary,
        content,
        media_type,
        url,
        attributed_to,
        attachments,
        tags,
        published,
        updated,
        sensitive,
        source_content,
        source_media_type
      )
    end
  end

  standard_object_builder article, "Article"
  standard_object_builder audio, "Audio"
  standard_object_builder document, "Document"
  standard_object_builder event, "Event"
  standard_object_builder image, "Image"
  standard_object_builder page, "Page"
  standard_object_builder place, "Place"
  standard_object_builder profile, "Profile"
  standard_object_builder relationship, "Relationship"
  standard_object_builder video, "Video"

  def self.link(
    href : String,
    rel : Array(String) = [] of String,
    media_type : String? = nil,
    name : String? = nil,
    hreflang : String? = nil,
    height : Int32? = nil,
    width : Int32? = nil,
    type : String = "Link"
  ) : JsonMap
    properties = JsonMap{
      "href" => json(href),
    }
    properties["rel"] = json(rel) unless rel.empty?
    properties["mediaType"] = json(media_type) if media_type
    properties["name"] = json(name) if name
    properties["hreflang"] = json(hreflang) if hreflang
    properties["height"] = json(height) if height
    properties["width"] = json(width) if width
    Aptok.object(type, nil, properties)
  end

  def self.mention(href : String, name : String? = nil) : JsonMap
    link(href, name: name, type: "Mention")
  end

  def self.hashtag(name : String, href : String? = nil) : JsonMap
    properties = JsonMap{
      "name" => json(name),
    }
    properties["href"] = json(href) if href
    Aptok.object("Hashtag", nil, properties)
  end

  def self.property_value(name : String, value : String) : JsonMap
    Aptok.object("PropertyValue", nil, JsonMap{
      "name"  => json(name),
      "value" => json(value),
    })
  end

  def self.emoji(id : String, name : String, icon : JsonMap | String) : JsonMap
    Aptok.object("Emoji", id, JsonMap{
      "name" => json(name),
      "icon" => json(icon),
    })
  end

  def self.tombstone(id : String, former_type : String? = nil, deleted : String? = nil) : JsonMap
    properties = JsonMap.new
    properties["formerType"] = json(former_type) if former_type
    properties["deleted"] = json(deleted) if deleted
    Aptok.object("Tombstone", id, properties)
  end

  def self.activity(
    type : String,
    id : String,
    actor : String,
    object : JsonMap | String,
    to : Array(String) = [PUBLIC_COLLECTION],
    target : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "actor"     => json(actor),
      "object"    => json(object),
      "to"        => json(to),
      "published" => json(now),
    }
    properties["target"] = json(target) if target
    Aptok.object(type, id, properties)
  end

  def self.intransitive_activity(
    type : String,
    id : String,
    actor : String,
    to : Array(String) = [PUBLIC_COLLECTION],
    target : JsonMap | String | Nil = nil,
    origin : JsonMap | String | Nil = nil
  ) : JsonMap
    properties = JsonMap{
      "actor"     => json(actor),
      "to"        => json(to),
      "published" => json(now),
    }
    properties["target"] = json(target) if target
    properties["origin"] = json(origin) if origin
    Aptok.object(type, id, properties)
  end

  def self.create(id : String, actor : String, object : JsonMap | String, to : Array(String) = [PUBLIC_COLLECTION], target : String? = nil) : JsonMap
    activity("Create", id, actor, object, to, target)
  end

  macro activity_builder(method_name, type_name)
    def self.{{method_name.id}}(id : String, actor : String, object : JsonMap | String, to : Array(String) = [PUBLIC_COLLECTION], target : String? = nil) : JsonMap
      activity({{type_name}}, id, actor, object, to, target)
    end
  end

  activity_builder accept, "Accept"
  activity_builder add, "Add"
  activity_builder announce, "Announce"
  activity_builder block, "Block"
  activity_builder delete, "Delete"
  activity_builder dislike, "Dislike"
  activity_builder flag, "Flag"
  activity_builder follow, "Follow"
  activity_builder ignore, "Ignore"
  activity_builder invite, "Invite"
  activity_builder join, "Join"
  activity_builder leave, "Leave"
  activity_builder like, "Like"
  activity_builder listen, "Listen"
  activity_builder move, "Move"
  activity_builder offer, "Offer"
  activity_builder reject, "Reject"
  activity_builder read, "Read"
  activity_builder remove, "Remove"
  activity_builder tentative_accept, "TentativeAccept"
  activity_builder tentative_reject, "TentativeReject"
  activity_builder undo, "Undo"
  activity_builder update, "Update"
  activity_builder view, "View"

  def self.arrive(id : String, actor : String, to : Array(String) = [PUBLIC_COLLECTION], target : JsonMap | String | Nil = nil, origin : JsonMap | String | Nil = nil) : JsonMap
    intransitive_activity("Arrive", id, actor, to, target, origin)
  end

  def self.travel(id : String, actor : String, to : Array(String) = [PUBLIC_COLLECTION], target : JsonMap | String | Nil = nil, origin : JsonMap | String | Nil = nil) : JsonMap
    intransitive_activity("Travel", id, actor, to, target, origin)
  end

  def self.question(
    id : String,
    actor : String,
    one_of : Array(JsonMap | String) = [] of JsonMap | String,
    any_of : Array(JsonMap | String) = [] of JsonMap | String,
    to : Array(String) = [PUBLIC_COLLECTION],
    end_time : String? = nil,
    closed : Bool? = nil
  ) : JsonMap
    properties = JsonMap{
      "actor"     => json(actor),
      "to"        => json(to),
      "published" => json(now),
    }
    properties["oneOf"] = json(one_of) unless one_of.empty?
    properties["anyOf"] = json(any_of) unless any_of.empty?
    properties["endTime"] = json(end_time) if end_time
    properties["closed"] = json(closed) unless closed.nil?
    Aptok.object("Question", id, properties)
  end

  def self.forgefed_object(type : String, id : String, properties : JsonMap = JsonMap.new) : JsonMap
    properties = properties.dup
    properties["@context"] = json([ACTIVITYSTREAMS_CONTEXT, FORGEFED_CONTEXT])
    Aptok.object(type, id, properties)
  end

  def self.forgefed_repository(
    id : String,
    name : String,
    inbox : String,
    outbox : String,
    clone_uri : String? = nil,
    push_uris : Array(String) = [] of String,
    summary : String? = nil,
    followers : String? = nil,
    likes : String? = nil,
    tickets_tracked_by : String? = nil,
    send_patches_to : String? = nil,
    context : String? = nil,
    public_key : JsonMap? = nil,
    archived : Bool = false,
    moved_to : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "name"      => json(name),
      "inbox"     => json(inbox),
      "outbox"    => json(outbox),
      "published" => json(now),
    }
    properties["cloneUri"] = json(clone_uri) if clone_uri
    properties["pushUri"] = json(push_uris) unless push_uris.empty?
    properties["summary"] = json(summary) if summary
    properties["followers"] = json(followers) if followers
    properties["likes"] = json(likes) if likes
    properties["ticketsTrackedBy"] = json(tickets_tracked_by) if tickets_tracked_by
    properties["sendPatchesTo"] = json(send_patches_to) if send_patches_to
    properties["context"] = json(context) if context
    properties["publicKey"] = json(public_key) if public_key
    properties["isArchived"] = json(true) if archived
    properties["movedTo"] = json(moved_to) if moved_to
    forgefed_object("Repository", id, properties)
  end
end
