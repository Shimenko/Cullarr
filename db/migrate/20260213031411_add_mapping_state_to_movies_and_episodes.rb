class AddMappingStateToMoviesAndEpisodes < ActiveRecord::Migration[8.0]
  STATUSES_SQL_LIST = "'verified_path','verified_external_ids','verified_tv_structure'," \
    "'provisional_title_year','external_source_not_managed','unresolved','ambiguous_conflict'".freeze

  def up
    add_mapping_columns(:movies)
    add_mapping_columns(:episodes)

    add_index :movies, :mapping_status_code
    add_index :episodes, :mapping_status_code

    add_check_constraint :movies,
      "mapping_status_code IN (#{STATUSES_SQL_LIST})",
      name: "movies_mapping_status_code_v2_check"
    add_check_constraint :episodes,
      "mapping_status_code IN (#{STATUSES_SQL_LIST})",
      name: "episodes_mapping_status_code_v2_check"
  end

  def down
    remove_check_constraint :movies, name: "movies_mapping_status_code_v2_check"
    remove_check_constraint :episodes, name: "episodes_mapping_status_code_v2_check"

    remove_index :movies, :mapping_status_code
    remove_index :episodes, :mapping_status_code

    remove_mapping_columns(:movies)
    remove_mapping_columns(:episodes)
  end

  private

  def add_mapping_columns(table_name)
    add_column table_name, :mapping_status_code, :string, null: false, default: "unresolved"
    add_column table_name, :mapping_strategy, :string, null: false, default: "no_match"
    add_column table_name, :mapping_diagnostics_json, :json, null: false, default: {}
    add_column table_name, :mapping_status_changed_at, :datetime
  end

  def remove_mapping_columns(table_name)
    remove_column table_name, :mapping_status_code
    remove_column table_name, :mapping_strategy
    remove_column table_name, :mapping_diagnostics_json
    remove_column table_name, :mapping_status_changed_at
  end
end
