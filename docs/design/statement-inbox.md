# Statement Inbox — Design Document

**Date:** 2026-04-17
**Status:** Draft
**Author:** Álvaro / Claude design session

## Problem

Bank and credit card statements (PDFs) are downloaded manually and imported one-by-one through Sure's UI. This is tedious for someone managing multiple accounts across issuers (Amex, Banamex, INVEX, HSBC). We want a "drop folder" workflow: place a PDF in a known directory, and Sure picks it up, extracts transactions via AI, and queues them for review.

## Goals

- Automatically detect new PDF statements in a configured folder
- Deduplicate: never re-process the same file, even if renamed
- Leverage the existing `PdfImport` + `ProcessPdfJob` pipeline (AI-only extraction)
- Always require manual review before publishing (no auto-publish)
- Support scheduling (e.g., run daily or on-demand via rake task)
- Track ingestion history for auditability

## Non-Goals (for now)

- Fetching statements from email or banking portals (future Layer 2)
- Issuer-specific template parsers (rely on AI extraction)
- Auto-publishing or auto-categorization rules
- Multi-family support (single family instance assumed)

---

## Architecture

### New Components

```
┌─────────────────────────────────────────────────────────┐
│  /path/to/statements/  (configured folder)              │
│  ├── 202603.pdf                                         │
│  ├── 2026-04-09_Estado_de_cuenta.pdf                    │
│  └── new_statement.pdf  ← dropped by user               │
└──────────────────────────┬──────────────────────────────┘
                           │
          ┌────────────────▼────────────────┐
          │   StatementIngestionJob          │
          │   (Sidekiq, scheduled or manual) │
          │                                  │
          │  1. Scan folder for *.pdf        │
          │  2. SHA256 each file             │
          │  3. Skip if hash in manifest     │
          │  4. Create PdfImport + attach    │
          │  5. Record in manifest           │
          │  6. Trigger ProcessPdfJob        │
          └────────────────┬────────────────┘
                           │
          ┌────────────────▼────────────────┐
          │   Existing Pipeline              │
          │                                  │
          │  ProcessPdfJob                   │
          │  → AI classification             │
          │  → Transaction extraction        │
          │  → Row generation                │
          │  → Email notification            │
          │  → Status: pending (for review)  │
          └─────────────────────────────────┘
```

### 1. Database: `ingested_statements` table

```ruby
# db/migrate/XXXXXXXX_create_ingested_statements.rb
class CreateIngestedStatements < ActiveRecord::Migration[7.2]
  def change
    create_table :ingested_statements, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :import, type: :uuid, foreign_key: { to_table: :imports }

      t.string  :file_hash,     null: false  # SHA256 of file content
      t.string  :original_filename, null: false
      t.integer :file_size,     null: false  # bytes
      t.string  :source_path,   null: false  # full path at time of ingestion
      t.string  :status,        null: false, default: "ingested"
        # ingested  → PdfImport created, ProcessPdfJob queued
        # failed    → error during ingestion (not AI processing)
        # skipped   → file couldn't be read or wasn't a PDF
      t.string  :error_message
      t.datetime :ingested_at,  null: false

      t.timestamps
    end

    add_index :ingested_statements, [:family_id, :file_hash], unique: true
    add_index :ingested_statements, :status
  end
end
```

**Deduplication strategy:** The `file_hash` (SHA256 of raw bytes) is the primary dedup key, scoped per family. This means:
- Same file renamed → detected as duplicate (same content hash)
- Same statement re-downloaded (identical PDF) → duplicate
- Statement with one extra byte different → treated as new (edge case, acceptable)

### 2. Model: `IngestedStatement`

```ruby
# app/models/ingested_statement.rb
class IngestedStatement < ApplicationRecord
  belongs_to :family
  belongs_to :import, optional: true

  validates :file_hash, presence: true, uniqueness: { scope: :family_id }
  validates :original_filename, :file_size, :source_path, :ingested_at, presence: true

  enum :status, {
    ingested: "ingested",
    failed: "failed",
    skipped: "skipped"
  }

  scope :recent, -> { order(ingested_at: :desc) }
end
```

### 3. Model: `StatementInbox`

Business logic PORO — follows Sure's "fat models" convention.

```ruby
# app/models/statement_inbox.rb
class StatementInbox
  SUPPORTED_EXTENSIONS = %w[.pdf].freeze
  MAX_FILE_SIZE = 25.megabytes  # matches PdfImport limit

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
```

### 4. Background Job: `StatementIngestionJob`

```ruby
# app/jobs/statement_ingestion_job.rb
class StatementIngestionJob < ApplicationJob
  queue_as :scheduled

  def perform(family_id: nil, inbox_path: nil)
    families = if family_id
      Family.where(id: family_id)
    else
      Family.all
    end

    families.find_each do |family|
      inbox = StatementInbox.new(family, inbox_path: inbox_path)
      results = inbox.scan

      if results[:ingested] > 0 || results[:failed] > 0
        Rails.logger.info(
          "[StatementIngestion] family=#{family.id} " \
          "ingested=#{results[:ingested]} duplicate=#{results[:duplicate]} " \
          "skipped=#{results[:skipped]} failed=#{results[:failed]}"
        )
      end
    end
  end
end
```

### 5. Scheduling (sidekiq-cron)

Add to `AutoSyncScheduler` or create a parallel `StatementInboxScheduler`:

```ruby
# app/services/statement_inbox_scheduler.rb
class StatementInboxScheduler
  JOB_NAME = "ingest_statements"

  def self.sync!
    if ENV["STATEMENT_INBOX_PATH"].present?
      upsert_job
    else
      remove_job
    end
  end

  def self.upsert_job
    Sidekiq::Cron::Job.create(
      name: JOB_NAME,
      cron: ENV.fetch("STATEMENT_INBOX_CRON", "0 */6 * * *"),  # every 6 hours
      class: "StatementIngestionJob",
      queue: "scheduled",
      description: "Scans statement inbox folder for new PDFs"
    )
  end

  def self.remove_job
    if (job = Sidekiq::Cron::Job.find(JOB_NAME))
      job.destroy
    end
  end
end
```

Initialize in `config/initializers/sidekiq.rb`:

```ruby
config.on(:startup) do
  AutoSyncScheduler.sync!
  StatementInboxScheduler.sync!  # ← add this
end
```

### 6. Rake Task (manual trigger)

```ruby
# lib/tasks/statements.rake
namespace :statements do
  desc "Scan statement inbox folder and ingest new PDFs"
  task ingest: :environment do
    inbox_path = ENV.fetch("STATEMENT_INBOX_PATH") do
      abort "Set STATEMENT_INBOX_PATH to the folder containing statement PDFs"
    end

    Family.find_each do |family|
      inbox = StatementInbox.new(family, inbox_path: inbox_path)
      results = inbox.scan
      puts "Family #{family.name}: #{results.inspect}"
    end
  end

  desc "Show ingestion history"
  task history: :environment do
    IngestedStatement.recent.limit(50).each do |record|
      puts "#{record.ingested_at.strftime('%Y-%m-%d %H:%M')} | " \
           "#{record.status.ljust(8)} | #{record.original_filename} | " \
           "#{record.import_id || 'no import'}"
    end
  end
end
```

### 7. Family Association

```ruby
# Add to app/models/family.rb
has_many :ingested_statements, dependent: :destroy
```

---

## Configuration

| Env Variable | Default | Description |
|---|---|---|
| `STATEMENT_INBOX_PATH` | *(none — feature disabled)* | Absolute path to the folder to watch |
| `STATEMENT_INBOX_CRON` | `0 */6 * * *` | Cron schedule (default: every 6 hours) |

When `STATEMENT_INBOX_PATH` is not set, the scheduler doesn't register the cron job and the feature is completely inert.

---

## User Flow

1. **Setup:** Set `STATEMENT_INBOX_PATH=/path/to/statements` in `.env`
2. **Drop files:** Save/move new PDF statements into that folder
3. **Automatic:** Every 6 hours (or per cron), `StatementIngestionJob` runs:
   - Finds new PDFs (not in manifest by content hash)
   - Creates `PdfImport` records, attaches files, triggers AI extraction
4. **Review:** In Sure's UI, new imports appear in the imports list with status "pending"
   - Review extracted transactions, fix any errors
   - Select target account (or use default if pre-configured)
   - Map categories
   - Publish when satisfied
5. **History:** `bin/rails statements:history` shows what's been processed

---

## Edge Cases & Decisions

| Scenario | Behavior |
|---|---|
| Same PDF copied with different name | Detected as duplicate (same SHA256) |
| Corrupted PDF | Recorded as `failed`, logged, won't retry |
| Non-PDF in folder | Ignored (only `*.pdf` globbed) |
| Folder doesn't exist | `scan` returns early, no error |
| AI extraction fails | `ProcessPdfJob` handles this → import status becomes `failed` |
| Multiple families | Each family gets its own dedup scope; configurable per-family in future |
| File modified after ingestion | New hash → treated as new file (re-ingested) |
| Subfolder PDFs | Included (recursive glob `**/*.pdf`) |

---

## Future Extensions

1. **Email fetching:** Gmail/Outlook MCP to pull attachments → save to inbox folder → existing pipeline handles the rest
2. **Account auto-assignment:** Use AI classification metadata (bank name, account number) to auto-select the target account
3. **Confidence scoring:** If AI extraction confidence is high enough, allow auto-publish for trusted issuers
4. **UI panel:** Add a "Statement Inbox" section in Sure's settings to view ingestion history, configure path, and manually trigger scans
5. **Per-family inbox paths:** Store path in `settings` table instead of ENV for multi-family setups

---

## Files to Create/Modify

### New Files
- `db/migrate/XXXXXXXX_create_ingested_statements.rb`
- `app/models/ingested_statement.rb`
- `app/models/statement_inbox.rb`
- `app/jobs/statement_ingestion_job.rb`
- `app/services/statement_inbox_scheduler.rb`
- `lib/tasks/statements.rake`
- `test/models/ingested_statement_test.rb`
- `test/models/statement_inbox_test.rb`
- `test/jobs/statement_ingestion_job_test.rb`

### Modified Files
- `app/models/family.rb` — add `has_many :ingested_statements`
- `config/initializers/sidekiq.rb` — add `StatementInboxScheduler.sync!`
