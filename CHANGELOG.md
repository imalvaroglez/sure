# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

#### Automated Bank Statement Ingestion Pipeline (Statement Inbox)
Introduced a "drop folder" architecture to ingest bank and credit card PDF statements automatically into the system. This allows Sure to monitor a local directory, autonomously scan for financial statements, pass them to the AI transaction extractor, and queue them for user review.

**Technical Details:**
- **`IngestedStatement` model & database migration**: 
  - Maintains a full audit trail of files scanned.
  - Implements SHA-256 deduplication scoped to the `family_id` to guarantee that the same file is never ingested or processed twice—even if it remains in the inbox folder across multiple system cycles.
  - Exposes statuses: `ingested`, `skipped` (due to duplicates or > 25MB file size limits), and `failed`.
- **`StatementInbox` PORO**: 
  - The business logic orchestrator that scans the folder recursively, computes file hashes, and safely attaches the file to a standard `PdfImport`. 
  - Pre-flight `Provider` Checks: It verifies that the AI context (`Provider::Registry.get_provider(:openai)`) is correctly configured and has vision context enabled before blindly throwing PDFs at the inference engine.
- **`StatementIngestionJob`**: The Sidekiq background orchestrator that binds a Family parameter to the scanner logic.
- **`StatementInboxScheduler`**: Automatically injected into Sidekiq's `config.on(:startup)` hook via `sidekiq-cron`, invoking the job every 6 hours by default.
- **Testing**: End-to-end unit and job coverage ensuring graceful failure behavior (e.g. absent folders, simulated DB errors, oversized documents, missing AI config, duplication coverage).

<br>

**Usage Example:**

To utilize the statement inbox on a local or self-hosted basis, configure the target folder path via Environment Variables.

**1. Configure your `.env.local`:**
```env
# Required: The absolute system path to monitor for PDFs
STATEMENT_INBOX_PATH=/Users/shared/financial_statements

# Optional: Override the scanning schedule (default is every 6 hours: "0 */6 * * *")
STATEMENT_INBOX_CRON="0 * * * *" 
```

**2. Place PDFs into the monitored folder:**
```bash
# Save your downloaded PDFs anywhere locally
cp bank_january.pdf /Users/shared/financial_statements/
```

**3. Application Behavior:**
The system will detect `bank_january.pdf` during its next chron-cycle. After verifying the file hash, it will create a `PdfImport` record, invoke your configured AI Provider to extract the line items, and finally place the statement into a `pending` status where you can assign it an Account through the standard Sure web interface.

**4. Manual Override / Tools (Rake Tasks):**
If you wish to force the system to ingest statements immediately without waiting for the next cron-cycle:
```bash
# Force an immediate scan over STATEMENT_INBOX_PATH
bin/rails statements:ingest

# Display the 50 most recent ingestion events and their statuses (ingested/skipped/failed)
bin/rails statements:history
```
