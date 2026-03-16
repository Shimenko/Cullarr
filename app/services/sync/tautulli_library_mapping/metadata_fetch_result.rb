module Sync
  module TautulliLibraryMapping
    MetadataFetchResult = Struct.new(
      :metadata,
      :call_issued,
      :budget_exhausted,
      :missing_key,
      keyword_init: true
    )
  end
end
