require "test_helper"

class IngestedStatementTest < ActiveSupport::TestCase
  def setup
    @ingested_statement = ingested_statements(:ingested_one)
  end

  test "valid fixture" do
    assert @ingested_statement.valid?
  end

  test "requires file_hash" do
    @ingested_statement.file_hash = nil
    assert_not @ingested_statement.valid?
  end

  test "file_hash is unique per family" do
    duplicate = @ingested_statement.dup
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:file_hash], "has already been taken"

    # Different family, same hash is permitted
    duplicate.family = families(:empty)
    assert duplicate.valid?
  end

  test "requires original_filename" do
    @ingested_statement.original_filename = nil
    assert_not @ingested_statement.valid?
  end

  test "requires file_size" do
    @ingested_statement.file_size = nil
    assert_not @ingested_statement.valid?
  end

  test "requires source_path" do
    @ingested_statement.source_path = nil
    assert_not @ingested_statement.valid?
  end

  test "requires ingested_at" do
    @ingested_statement.ingested_at = nil
    assert_not @ingested_statement.valid?
  end

  test "recent scope orders by ingested_at descending" do
    assert_equal IngestedStatement.recent.first, ingested_statements(:ingested_one)

    # create a newer one
    newer = ingested_statements(:failed_one).dup
    newer.file_hash = "newer"
    newer.ingested_at = 1.day.from_now
    newer.save!

    assert_equal IngestedStatement.recent.first, newer
  end
end
