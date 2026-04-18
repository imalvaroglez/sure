class StatementInbox
  SUPPORTED_EXTENSIONS = %w[.pdf].freeze
  MAX_FILE_SIZE = 25.megabytes

  attr_reader :family, :inbox_path, :results

  def initialize(family, inbox_path: nil)
    @family = family
    @inbox_path = inbox_path || ENV.fetch("STATEMENT_INBOX_PATH", nil)
    @results = { ingested: 0, skipped: 0, failed: 0, duplicate: 0 }
  end

  def scan
    return results unless inbox_path.present? && Dir.exist?(inbox_path)

    pdf_files.each do |file_path|
      process_file(file_path)
    end

    results
  end

  private

    def pdf_files
      Dir.glob(File.join(inbox_path, "**", "*.pdf")).sort
    end

    def process_file(file_path)
      file_content = File.binread(file_path)
      file_hash = Digest::SHA256.hexdigest(file_content)

      # Dedup check
      if family.ingested_statements.exists?(file_hash: file_hash)
        @results[:duplicate] += 1
        return
      end

      # Size check
      if file_content.size > MAX_FILE_SIZE
        record_skip(file_path, file_hash, file_content.size, "File exceeds #{MAX_FILE_SIZE / 1.megabyte}MB limit")
        return
      end

      # Provider check
      provider = Provider::Registry.get_provider(:openai)
      unless provider.present? && provider.supports_pdf_processing?
        error_msg = provider.present? ? "AI Provider does not support PDF processing" : "AI Provider not configured"
        record_failure(file_path, file_hash, file_content.size, error_msg)
        return
      end

      ingest(file_path, file_hash, file_content)
    rescue => e
      record_failure(file_path, file_hash, file_content&.size || 0, e.message)
    end

    def ingest(file_path, file_hash, file_content)
      filename = File.basename(file_path)

      ActiveRecord::Base.transaction do
        # Create the PdfImport (leveraging existing pipeline)
        pdf_import = family.imports.create!(
          type: "PdfImport",
          status: :pending
        )

        # Attach the PDF file
        pdf_import.pdf_file.attach(
          io: StringIO.new(file_content),
          filename: filename,
          content_type: "application/pdf"
        )

        # Record in manifest
        family.ingested_statements.create!(
          import: pdf_import,
          file_hash: file_hash,
          original_filename: filename,
          file_size: file_content.size,
          source_path: file_path,
          status: :ingested,
          ingested_at: Time.current
        )

        # Trigger existing AI processing pipeline
        pdf_import.process_with_ai_later
      end

      @results[:ingested] += 1
    end

    def record_skip(file_path, file_hash, file_size, reason)
      family.ingested_statements.create!(
        file_hash: file_hash || Digest::SHA256.hexdigest(file_path),
        original_filename: File.basename(file_path),
        file_size: file_size,
        source_path: file_path,
        status: :skipped,
        error_message: reason,
        ingested_at: Time.current
      )
      @results[:skipped] += 1
    end

    def record_failure(file_path, file_hash, file_size, error)
      family.ingested_statements.create!(
        file_hash: file_hash || Digest::SHA256.hexdigest(file_path),
        original_filename: File.basename(file_path),
        file_size: file_size,
        source_path: file_path,
        status: :failed,
        error_message: error.truncate(500),
        ingested_at: Time.current
      )
      @results[:failed] += 1
    rescue => e
      Rails.logger.error("[StatementInbox] Failed to record failure for #{file_path}: #{e.message}")
    end
end
