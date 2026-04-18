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
