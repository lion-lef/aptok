module Aptok
  def self.marketplace_context : JSON::Any
    json([
      ACTIVITYSTREAMS_CONTEXT,
      {
        "om2"                  => OM2_CONTEXT,
        "vf"                   => VALUEFLOWS_CONTEXT,
        "Proposal"             => "vf:Proposal",
        "Intent"               => "vf:Intent",
        "Agreement"            => "vf:Agreement",
        "Commitment"           => "vf:Commitment",
        "action"               => "vf:action",
        "purpose"              => "vf:purpose",
        "unitBased"            => "vf:unitBased",
        "publishes"            => "vf:publishes",
        "reciprocal"           => "vf:reciprocal",
        "stipulates"           => "vf:stipulates",
        "stipulatesReciprocal" => "vf:stipulatesReciprocal",
        "satisfies"            => "vf:satisfies",
        "resourceConformsTo"   => "vf:resourceConformsTo",
        "resourceQuantity"     => "vf:resourceQuantity",
        "availableQuantity"    => "vf:availableQuantity",
        "minimumQuantity"      => "vf:minimumQuantity",
        "hasUnit"              => "om2:hasUnit",
        "hasNumericalValue"    => "om2:hasNumericalValue",
      },
    ])
  end
end
