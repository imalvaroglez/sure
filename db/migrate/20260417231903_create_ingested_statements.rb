class CreateIngestedStatements < ActiveRecord::Migration[7.2]
  def change
    create_table :ingested_statements, id: :uuid do |t|
      t.references :family,  type: :uuid, null: false, foreign_key: true
      t.references :import,  type: :uuid, foreign_key: { to_table: :imports }

      t.string   :file_hash,         null: false
      t.string   :original_filename, null: false
      t.integer  :file_size,         null: false
      t.string   :source_path,       null: false
      t.string   :status,            null: false, default: "ingested"
      t.string   :error_message
      t.datetime :ingested_at,       null: false

      t.timestamps
    end

    add_index :ingested_statements, [:family_id, :file_hash], unique: true
    add_index :ingested_statements, :status
  end
end
