class MyAwesomeMigration < ActiveRecord::Migration[5.2]
  set_lock_timeout(750)
  set_statement_timeout(1500)

  
  def up
  
    change_column(
  :payments,
  :foo,
  {
  null: true
}
)

  
  end
  
end