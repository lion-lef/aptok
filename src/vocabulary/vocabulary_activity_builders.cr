module Aptok
  def self.forgefed_project(
    id : String,
    name : String,
    inbox : String? = nil,
    outbox : String? = nil,
    summary : String? = nil,
    followers : String? = nil,
    context : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "name"      => json(name),
      "published" => json(now),
    }
    properties["inbox"] = json(inbox) if inbox
    properties["outbox"] = json(outbox) if outbox
    properties["summary"] = json(summary) if summary
    properties["followers"] = json(followers) if followers
    properties["context"] = json(context) if context
    forgefed_object("Project", id, properties)
  end

  def self.forgefed_branch(
    id : String,
    repository : String,
    name : String,
    ref : String,
    team : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "context" => json(repository),
      "name"    => json(name),
      "ref"     => json(ref),
    }
    properties["team"] = json(team) if team
    forgefed_object("Branch", id, properties)
  end

  def self.forgefed_tag(
    id : String,
    name : String,
    context : String? = nil,
    href : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "name" => json(name),
    }
    properties["context"] = json(context) if context
    properties["href"] = json(href) if href
    forgefed_object("Tag", id, properties)
  end

  def self.forgefed_ticket_tracker(
    id : String,
    name : String,
    context : String? = nil,
    inbox : String? = nil,
    outbox : String? = nil
  ) : JsonMap
    forgefed_tracker("TicketTracker", id, name, context, inbox, outbox)
  end

  def self.forgefed_patch_tracker(
    id : String,
    name : String,
    context : String? = nil,
    inbox : String? = nil,
    outbox : String? = nil
  ) : JsonMap
    forgefed_tracker("PatchTracker", id, name, context, inbox, outbox)
  end

  private def self.forgefed_tracker(
    type : String,
    id : String,
    name : String,
    context : String?,
    inbox : String?,
    outbox : String?
  ) : JsonMap
    properties = JsonMap{
      "name" => json(name),
    }
    properties["context"] = json(context) if context
    properties["inbox"] = json(inbox) if inbox
    properties["outbox"] = json(outbox) if outbox
    forgefed_object(type, id, properties)
  end

  def self.forgefed_commit(
    id : String,
    repository : String,
    hash : String,
    attributed_to : String,
    summary : String,
    created : String = now,
    description : String? = nil,
    committed_by : String? = nil,
    committed : String? = nil,
    files_added : Array(String) = [] of String,
    files_modified : Array(String) = [] of String,
    files_removed : Array(String) = [] of String
  ) : JsonMap
    properties = JsonMap{
      "context"      => json(repository),
      "attributedTo" => json(attributed_to),
      "created"      => json(created),
      "hash"         => json(hash),
      "summary"      => json(summary),
    }
    properties["committedBy"] = json(committed_by) if committed_by
    properties["committed"] = json(committed) if committed
    properties["filesAdded"] = json(files_added) unless files_added.empty?
    properties["filesModified"] = json(files_modified) unless files_modified.empty?
    properties["filesRemoved"] = json(files_removed) unless files_removed.empty?
    if description
      properties["description"] = json({
        "mediaType" => "text/plain",
        "content"   => description,
      })
    end
    forgefed_object("Commit", id, properties)
  end

  def self.forgefed_push(
    id : String,
    repository : String,
    attributed_to : String,
    target : String,
    commits : Array(JsonMap),
    hash_before : String,
    hash_after : String,
    to : Array(String) = [PUBLIC_COLLECTION]
  ) : JsonMap
    properties = JsonMap{
      "@context"     => json([ACTIVITYSTREAMS_CONTEXT, FORGEFED_CONTEXT]),
      "actor"        => json(repository),
      "attributedTo" => json(attributed_to),
      "context"      => json(repository),
      "target"       => json(target),
      "hashBefore"   => json(hash_before),
      "hashAfter"    => json(hash_after),
      "object"       => json(ordered_collection("#{id}/commits", commits)),
      "to"           => json(to),
      "published"    => json(now),
    }
    Aptok.object("Push", id, properties)
  end

  def self.forgefed_ticket(
    id : String,
    title : String,
    content : String,
    assignee : String? = nil,
    attributed_to : String? = nil,
    context : String? = nil,
    resolved : Bool? = nil,
    attachment : Array(JsonMap) = [] of JsonMap,
    depends_on : Array(JsonMap | String) = [] of JsonMap | String,
    dependants : Array(JsonMap | String) = [] of JsonMap | String
  ) : JsonMap
    properties = JsonMap{
      "@context" => json([ACTIVITYSTREAMS_CONTEXT, FORGEFED_CONTEXT]),
      "name"     => json(title),
      "content"  => json(content),
    }
    properties["assignee"] = json(assignee) if assignee && !assignee.empty?
    properties["attributedTo"] = json(attributed_to) if attributed_to && !attributed_to.empty?
    properties["context"] = json(context) if context && !context.empty?
    properties["resolved"] = json(resolved) unless resolved.nil?
    properties["attachment"] = json(attachment) unless attachment.empty?
    properties["dependsOn"] = json(depends_on) unless depends_on.empty?
    properties["dependants"] = json(dependants) unless dependants.empty?
    Aptok.object("Ticket", id, properties)
  end

  def self.forgefed_ticket_dependency(
    id : String,
    subject : JsonMap | String,
    object : JsonMap | String,
    attributed_to : String? = nil,
    summary : String? = nil,
    published : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "@context"     => json([ACTIVITYSTREAMS_CONTEXT, FORGEFED_CONTEXT]),
      "type"         => json(["Relationship", "TicketDependency"]),
      "subject"      => json(subject),
      "relationship" => json("dependsOn"),
      "object"       => json(object),
      "published"    => json(published || now),
    }
    properties["attributedTo"] = json(attributed_to) if attributed_to && !attributed_to.empty?
    properties["summary"] = json(summary) if summary && !summary.empty?
    Aptok.object("Relationship", id, properties)
  end

  def self.forgefed_activity(
    type : String,
    id : String,
    actor : String,
    object : JsonMap | String,
    to : Array(String) = [PUBLIC_COLLECTION],
    target : JsonMap | String | Nil = nil
  ) : JsonMap
    properties = JsonMap{
      "@context"  => json([ACTIVITYSTREAMS_CONTEXT, FORGEFED_CONTEXT]),
      "actor"     => json(actor),
      "object"    => json(object),
      "to"        => json(to),
      "published" => json(now),
    }
    properties["target"] = json(target) if target
    Aptok.object(type, id, properties)
  end

  macro forgefed_activity_builder(method_name, type_name)
    def self.{{method_name.id}}(
      id : String,
      actor : String,
      object : JsonMap | String,
      to : Array(String) = [PUBLIC_COLLECTION],
      target : JsonMap | String | Nil = nil
    ) : JsonMap
      forgefed_activity({{type_name}}, id, actor, object, to, target)
    end
  end

  forgefed_activity_builder forgefed_resolve, "Resolve"
  forgefed_activity_builder forgefed_apply, "Apply"
  forgefed_activity_builder forgefed_grant, "Grant"
  forgefed_activity_builder forgefed_revoke, "Revoke"

  def self.forgefed_merge_request(
    id : String,
    title : String,
    content : String,
    patch_tracker : String,
    source_branch : String,
    target_branch : String,
    attributed_to : String? = nil,
    mr_diff : String? = nil,
    patches : Array(JsonMap) = [] of JsonMap
  ) : JsonMap
    offer = Aptok.object("Offer", nil, JsonMap{
      "@context" => json([ACTIVITYSTREAMS_CONTEXT, FORGEFED_CONTEXT]),
      "object"   => json(source_branch),
      "target"   => json(target_branch),
    })
    attachments = [offer]
    properties = JsonMap{
      "mrDiff" => json(mr_diff),
      "object" => json(ordered_collection("#{id}/patches", patches)),
    }
    ticket = forgefed_ticket(
      id,
      title,
      content,
      attributed_to: attributed_to,
      context: patch_tracker,
      attachment: attachments
    )
    ticket["mrDiff"] = json(mr_diff) if mr_diff
    ticket["object"] = properties["object"]
    ticket
  end

  def self.marketplace_offer(
    id : String,
    actor : String,
    item : JsonMap,
    name : String,
    price : String? = nil,
    currency : String? = nil,
    to : Array(String) = [PUBLIC_COLLECTION]
  ) : JsonMap
    properties = JsonMap{
      "@context" => json([ACTIVITYSTREAMS_CONTEXT, MARKETPLACE_CONTEXT]),
      "actor"    => json(actor),
      "name"     => json(name),
      "item"     => json(item),
      "to"       => json(to),
    }
    properties["price"] = json(price) if price
    properties["priceCurrency"] = json(currency) if currency
    Aptok.object("Offer", id, properties)
  end

  def self.marketplace_price_specification(
    price : String,
    currency : String,
    id : String? = nil,
    unit_text : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "@context"      => json([ACTIVITYSTREAMS_CONTEXT, MARKETPLACE_CONTEXT]),
      "price"         => json(price),
      "priceCurrency" => json(currency),
    }
    properties["unitText"] = json(unit_text) if unit_text
    Aptok.object("PriceSpecification", id, properties)
  end

  def self.marketplace_product(
    id : String,
    name : String,
    summary : String? = nil,
    attributed_to : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "@context" => json([ACTIVITYSTREAMS_CONTEXT, MARKETPLACE_CONTEXT]),
      "name"     => json(name),
    }
    properties["summary"] = json(summary) if summary
    properties["attributedTo"] = json(attributed_to) if attributed_to
    Aptok.object("Product", id, properties)
  end

  def self.marketplace_service(
    id : String,
    name : String,
    summary : String? = nil,
    attributed_to : String? = nil,
    provider : JsonMap | String | Nil = nil,
    terms_of_service : String? = nil
  ) : JsonMap
    properties = JsonMap{
      "@context" => json([ACTIVITYSTREAMS_CONTEXT, MARKETPLACE_CONTEXT]),
      "name"     => json(name),
    }
    properties["summary"] = json(summary) if summary
    properties["attributedTo"] = json(attributed_to) if attributed_to
    properties["provider"] = json(provider) if provider
    properties["termsOfService"] = json(terms_of_service) if terms_of_service
    Aptok.object("Service", id, properties)
  end
end
