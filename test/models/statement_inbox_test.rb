require "test_helper"

class StatementInboxTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @inbox_path = Rails.root.join("test/fixtures/files/statements").to_s
    FileUtils.mkdir_p(@inbox_path)
  end

  def teardown
    FileUtils.rm_rf(@inbox_path)
  end

  test "returns zeros when inbox_path is nil" do
    inbox = StatementInbox.new(@family, inbox_path: nil)
    results = inbox.scan

    assert_equal 0, results[:ingested]
    assert_equal 0, results[:failed]
    assert_equal 0, results[:skipped]
    assert_equal 0, results[:duplicate]
  end

  test "returns zeros when inbox_path does not exist" do
    inbox = StatementInbox.new(@family, inbox_path: "/tmp/non/existent/path/for/sure")
    results = inbox.scan

    assert_equal 0, results[:ingested]
  end

  test "skips oversized files" do
    file_path = File.join(@inbox_path, "large.pdf")
    File.write(file_path, "A" * (StatementInbox::MAX_FILE_SIZE + 1))

    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)
    assert_difference "IngestedStatement.count", 1 do
      results = inbox.scan
      assert_equal 1, results[:skipped]
    end

    statement = IngestedStatement.last
    assert_equal "skipped", statement.status
    assert_match /File exceeds/, statement.error_message
  end

  test "records failures when processing encounters an error" do
    file_path = File.join(@inbox_path, "test.pdf")
    File.write(file_path, "PDF content")

    # Mock provider but simulate failure in PdfImport creation
    mock_provider = OpenStruct.new(supports_pdf_processing?: true)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(mock_provider)

    @family.imports.stubs(:create!).raises(StandardError.new("Simulated DB error"))

    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)
    assert_difference "IngestedStatement.count", 1 do
      results = inbox.scan
      assert_equal 1, results[:failed]
    end

    statement = IngestedStatement.last
    assert_equal "failed", statement.status
    assert_equal "Simulated DB error", statement.error_message
  end

  test "records failure when AI provider is not configured" do
    file_path = File.join(@inbox_path, "test.pdf")
    File.write(file_path, "PDF content")

    Provider::Registry.stubs(:get_provider).with(:openai).returns(nil)

    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)
    assert_difference "IngestedStatement.count", 1 do
      results = inbox.scan
      assert_equal 1, results[:failed]
    end

    statement = IngestedStatement.last
    assert_equal "failed", statement.status
    assert_equal "AI Provider not configured", statement.error_message
  end

  test "records failure when AI provider does not support PDF processing" do
    file_path = File.join(@inbox_path, "test.pdf")
    File.write(file_path, "PDF content")

    mock_provider = OpenStruct.new(supports_pdf_processing?: false)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(mock_provider)

    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)
    assert_difference "IngestedStatement.count", 1 do
      results = inbox.scan
      assert_equal 1, results[:failed]
    end

    statement = IngestedStatement.last
    assert_equal "failed", statement.status
    assert_equal "AI Provider does not support PDF processing", statement.error_message
  end

  test "ingests new PDFs successfully" do
    file_path = File.join(@inbox_path, "test.pdf")
    File.write(file_path, "Valid PDF content")

    mock_provider = OpenStruct.new(supports_pdf_processing?: true)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(mock_provider)

    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)

    assert_difference ["IngestedStatement.count", "PdfImport.count"], 1 do
      assert_enqueued_with(job: ProcessPdfJob) do
        results = inbox.scan
        assert_equal 1, results[:ingested]
      end
    end

    statement = IngestedStatement.last
    assert_equal "ingested", statement.status
    assert_equal "test.pdf", statement.original_filename
    assert_not_nil statement.import_id

    pdf_import = statement.import
    assert pdf_import.pdf_file.attached?
    assert_equal "test.pdf", pdf_import.pdf_file.filename.to_s
  end

  test "skips duplicates via SHA256 deduplication" do
    file_path = File.join(@inbox_path, "test.pdf")
    content = "Valid PDF content"
    File.write(file_path, content)

    mock_provider = OpenStruct.new(supports_pdf_processing?: true)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(mock_provider)

    # First run ingests the file
    StatementInbox.new(@family, inbox_path: @inbox_path).scan

    # Second run should skip it as duplicate
    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)
    assert_no_difference ["IngestedStatement.count", "PdfImport.count"] do
      results = inbox.scan
      assert_equal 1, results[:duplicate]
    end

    # Even if renamed, it should be skipped if contents are same
    file_path2 = File.join(@inbox_path, "test2.pdf")
    File.write(file_path2, content)

    inbox2 = StatementInbox.new(@family, inbox_path: @inbox_path)
    assert_no_difference ["IngestedStatement.count", "PdfImport.count"] do
      results = inbox2.scan
      assert_equal 1, results[:duplicate] # Skips both old and new because both exist/duplicate
    end
  end

  test "scans subdirectories" do
    sub_dir = File.join(@inbox_path, "sub_dir")
    FileUtils.mkdir_p(sub_dir)
    file_path = File.join(sub_dir, "test.pdf")
    File.write(file_path, "PDF content")

    mock_provider = OpenStruct.new(supports_pdf_processing?: true)
    Provider::Registry.stubs(:get_provider).with(:openai).returns(mock_provider)

    inbox = StatementInbox.new(@family, inbox_path: @inbox_path)
    results = inbox.scan

    assert_equal 1, results[:ingested]
  end
end
