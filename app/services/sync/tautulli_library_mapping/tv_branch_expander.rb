module Sync
  module TautulliLibraryMapping
    class TvBranchExpander
      def initialize(integration:, adapter:, worker_count:, length:, adapter_factory: nil)
        @integration = integration
        @adapter = adapter
        @worker_count = worker_count.to_i
        @length = length
        @adapter_factory = adapter_factory || -> { Integrations::TautulliAdapter.new(integration: integration) }
      end

      def expand(root_rows:)
        return [] if root_rows.empty?
        return root_rows.map { |root_row| expand_branch(root_row:, adapter: adapter) } if serial_fallback?(root_rows)

        perform_parallel_expansion(root_rows:)
      end

      private

      attr_reader :adapter, :adapter_factory, :integration, :length, :worker_count

      def serial_fallback?(root_rows)
        worker_count <= 1 || root_rows.size < 2
      end

      def perform_parallel_expansion(root_rows:)
        work_queue = Queue.new
        results = Array.new(root_rows.size)
        error = nil
        error_lock = Mutex.new

        root_rows.each_with_index { |root_row, index| work_queue << [ index, root_row ] }

        actual_worker_count = [ worker_count, root_rows.size ].min
        workers = Array.new(actual_worker_count) { adapter_factory.call }
        actual_worker_count.times { work_queue << nil }

        threads = workers.map do |thread_adapter|
          Thread.new do
            loop do
              work_item = work_queue.pop
              break if work_item.nil?

              if error_lock.synchronize { error.present? }
                next
              end

              index, root_row = work_item
              results[index] = expand_branch(root_row:, adapter: thread_adapter)
            rescue StandardError => e
              error_lock.synchronize { error ||= e }
            end
          end
        end

        threads.each(&:join)
        raise error if error.present?

        results
      end

      def expand_branch(root_row:, adapter:)
        rows = []
        raw_rows_count = 0
        rows_skipped_invalid = 0
        child_page_calls = 0
        show_expansions = root_row[:media_type].to_s == "show" ? 1 : 0
        season_expansions = root_row[:media_type].to_s == "season" ? 1 : 0
        tv_rows_emitted = 0
        traversal_stack = [
          {
            frame_type: :page,
            rating_key: root_row.fetch(:plex_rating_key).to_s,
            start: 0,
            child_depth: 1
          }
        ]

        until traversal_stack.empty?
          frame = traversal_stack.pop
          if frame.fetch(:frame_type) == :row
            row = frame.fetch(:row)
            depth = frame.fetch(:depth)
            next if depth > 2

            case row[:media_type].to_s
            when "episode", "movie"
              rows << row
              tv_rows_emitted += 1
            when "show", "season"
              rating_key = row[:plex_rating_key].to_s.strip.presence
              if rating_key.blank?
                rows_skipped_invalid += 1
                next
              end

              show_expansions += 1 if row[:media_type].to_s == "show"
              season_expansions += 1 if row[:media_type].to_s == "season"

              traversal_stack << {
                frame_type: :page,
                rating_key: rating_key,
                start: 0,
                child_depth: depth + 1
              }
            else
              rows_skipped_invalid += 1
            end
            next
          end

          child_page_calls += 1
          child_page = adapter.fetch_library_media_page(
            rating_key: frame.fetch(:rating_key),
            start: frame.fetch(:start),
            length: length
          )
          raw_rows_count += child_page.fetch(:raw_rows_count, 0).to_i
          rows_skipped_invalid += child_page.fetch(:rows_skipped_invalid, 0).to_i

          if child_page.fetch(:has_more)
            traversal_stack << {
              frame_type: :page,
              rating_key: frame.fetch(:rating_key),
              start: child_page.fetch(:next_start).to_i,
              child_depth: frame.fetch(:child_depth)
            }
          end

          child_page.fetch(:rows).reverse_each do |child_row|
            traversal_stack << {
              frame_type: :row,
              row: child_row,
              depth: frame.fetch(:child_depth)
            }
          end
        end

        {
          rows: rows,
          raw_rows_count: raw_rows_count,
          rows_skipped_invalid: rows_skipped_invalid,
          child_page_calls: child_page_calls,
          show_expansions: show_expansions,
          season_expansions: season_expansions,
          tv_rows_emitted: tv_rows_emitted
        }
      end
    end
  end
end
