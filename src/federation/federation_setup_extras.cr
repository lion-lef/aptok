module Aptok
  class Federation
    def self.attachment_array_normalizer : ActivityTransformer
      ->(_ctx : Context, _transform : ActivityTransformContext, activity : JsonMap) do
        normalize_attachment_values(activity)
        activity
      end
    end
  end
end
