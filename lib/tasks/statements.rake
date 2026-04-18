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
