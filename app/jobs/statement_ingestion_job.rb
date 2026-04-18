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
