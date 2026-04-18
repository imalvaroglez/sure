class IngestedStatement < ApplicationRecord
  belongs_to :family
  belongs_to :import, optional: true

  validates :file_hash, presence: true, uniqueness: { scope: :family_id }
  validates :original_filename, :file_size, :source_path, :ingested_at, presence: true

  enum :status, {
    ingested: "ingested",
    failed:   "failed",
    skipped:  "skipped"
  }

  scope :recent, -> { order(ingested_at: :desc) }
end
