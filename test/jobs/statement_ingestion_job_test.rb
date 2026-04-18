require "test_helper"

class StatementIngestionJobTest < ActiveJob::TestCase
  def setup
    @family = families(:dylan_family)
  end

  test "processes all families when no family_id is provided" do
    inbox_mock = mock()
    inbox_mock.expects(:scan).returns({ ingested: 1, failed: 0, skipped: 0, duplicate: 0 }).times(Family.count)

    StatementInbox.expects(:new).times(Family.count).returns(inbox_mock)

    StatementIngestionJob.perform_now
  end

  test "processes specific family when family_id is provided" do
    inbox_mock = mock()
    inbox_mock.expects(:scan).returns({ ingested: 1, failed: 0, skipped: 0, duplicate: 0 }).once

    StatementInbox.expects(:new).with(@family, inbox_path: nil).returns(inbox_mock)

    StatementIngestionJob.perform_now(family_id: @family.id)
  end

  test "passes through inbox_path" do
    inbox_mock = mock()
    inbox_mock.expects(:scan).returns({ ingested: 1, failed: 0, skipped: 0, duplicate: 0 }).once

    StatementInbox.expects(:new).with(@family, inbox_path: "/custom/path").returns(inbox_mock)

    StatementIngestionJob.perform_now(family_id: @family.id, inbox_path: "/custom/path")
  end
end
