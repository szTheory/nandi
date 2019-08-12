# Nandi

Friendly Postgres migrations for people who don't want to take down their database to add a column!

## What does it do?

Nandi provides an alternative API to ActiveRecord's built-in Migration DSL for defining changes to your database schema.

ActiveRecord makes many changes easy. Unfortunately, that includes things that should be done with great care. Consider this migration, for example:

```rb
class AddBarIDToFoos < ActiveRecord::Migration[5.2]
  def change
    add_reference :foos, :bars, foreign_key: true
  end
end
```

This is a perfectly ordinary thing to want to do - add a reference from one table to another and add a foreign key constraint, so that `bar_id` will always contain a value that appears in `bars`. But this actually takes very strict locks on both tables, `foos` and `bars`, while it checks that the constraint is valid. Depending on how large a table `bars` is, that could take a while; and if it does, your app will basically grind to a halt if it needs to access these tables. There are many such pitfalls around; and they generally only become dangerous when your database hits a certain size. There is hopefully a grizzled veteran engineer on your team who has memorised all the danger through bitter experience of 3am pages and 10 page post-mortems. But shouldn't we be able to do this with sofware, instead of scar tissue?

Enter Nandi!

![nandi](https://user-images.githubusercontent.com/2285130/56881872-bef6f500-6a59-11e9-8936-04d3861b6dce.gif)

Nandi offers availability-safe implementations of most common schema changes. It produces plain old ActiveRecord migration files, so existing Rails tooling can be leveraged for everything apart from correctness.

## Getting started

Add to your Gemfile:

```rb
gem 'nandi'
gem 'activerecord-safer_migrations' # Also required
```

Generate a new migration:
```sh
rails generate nandi:migration add_widgets
```

You'll get a fresh file, by default in `db/safe_migrations`. Let's use it to create a table with two fields, a name and a price, and the standard timestamps:

```rb
# db/safe_migrations/20190606060606_add_widgets.rb

class AddWidgets < Nandi::Migration
  def up
    create_table :widgets do |t|
      t.text :name
      t.integer :price

      t.timestamps
    end
  end

  def down
    drop_table :widgets
  end
end
```

Looks good! So let's generate an actual runnable ActiveRecord migration file.

```sh
rails generate nandi:compile
```

The result will sort of look like this:

```rb
# db/migrate/20190606060606_add_widgets.rb

class AddWidgets < ActiveRecord::Migration[5.2]
  set_lock_timeout(750)
  set_statement_timeout(1500)

  def up
    create_table :widgets do |t|
      t.column :name, :text
      t.column :price, :integer
      t.timestamps
    end
  end

  def down
    drop_table :widgets
  end
end
```

(But not quite - the indentation is likely to be skewiff and some syntax will be oddly formatted. We have focused on making sure that the output is correct, rather than readable, although the dream is to one day have the same files that you would write yourself if you knew exactly what you were doing.)

Now we can run the migration as we normally would.

```sh
rails db:migrate
```

And we're done!

Now in this case, Nandi hasn't done much for us. It's explicitly set reasonable timeouts, so slow operations won't block other work indefinitely, and that's that. Let's try another.

```rb
# db/safe_migrations/20190606060606_add_widgets_index_on_name_and_price.rb

class AddWidgetsIndexOnNameAndPrice < Nandi::Migration
  def up
    add_index :widgets, [:name, :price]
  end

  def down
    remove_index :widgets, [:name, :price]
  end
end

# db/migrate/20190606060606_add_widgets_index_on_name_and_price.rb

class AddWidgetsIndexOnNameAndPrice < ActiveRecord::Migration[5.2]
  set_lock_timeout(750)
  set_statement_timeout(1500)

  disable_ddl_transaction!
  def up
    add_index(
      :widgets,
      %i[name price],
      name: :idx_widgets_on_name_price,
      algorithm: :concurrently,
      using: :btree,
    )
  end

  def down
    remove_index(
      :widgets,
      column: %i[name price],
      algorithm: :concurrently,
    )
  end
end
```

Nandi has added in the `algorithm: :concurrently` option, ensuring that the index is not built immediately with the table locked in the meantime (a common source of pain). You can't use that option within a transaction, however, so Nandi uses the `disable_ddl_transaction!` macro. And we're ready to go.

But wait a minute - what about the foreign key one we started out with? The grizzled veterans among you know the workaround: add the constraint with the `NOT VALID` flag set, and then - in a separate follow-up transaction - validate the constraint. Nandi makes this easy:

```sh
rails generate nandi:foreign_key foos bars
```

We now have two new migration files:

```rb
# db/safe_migrations/20190611124817_add_foreign_key_on_foos_to_bars.rb

class AddForeignKeyOnFoosToBars < Nandi::Migration
  def up
    add_foreign_key :foos, :bars
  end

  def down
    drop_constraint :foos, :foos_bars_fk
  end
end

# db/safe_migrations/20190611124818_validate_foreign_key_on_foos_to_bars.rb

class ValidateForeignKeyOnFoosToBars < Nandi::Migration
  def up
    validate_constraint :foos, :foos_bars_fk
  end

  def down; end
end
```

Which, when compiled, turns into some pretty hairy `execute` action:

```rb
# db/migrate/20190611124817_add_foreign_key_on_foos_to_bars.rb

class AddForeignKeyOnFoosToBars < ActiveRecord::Migration[5.2]
  set_lock_timeout(750)
  set_statement_timeout(1500)

  def up
    execute <<-SQL
    ALTER TABLE foos
    ADD_CONSTRAINT foos_bars_fk
    FOREIGN KEY (bar_id)
    REFERENCES bars (id)
    NOT VALID
    SQL
  end

  def down
    execute <<-SQL
    ALTER TABLE foos DROP CONSTRAINT foos_bars_fk
    SQL
  end
end

# db/migrate/20190611124818_validate_foreign_key_on_foos_to_bars.rb

# frozen_string_literal: true

class ValidateForeignKeyOnFoosToBars < ActiveRecord::Migration[5.2]
  set_lock_timeout(750)
  set_statement_timeout(1500)

  def up
    execute <<-SQL
    ALTER TABLE foos VALIDATE CONSTRAINT foos_bars_fk
    SQL
  end
end

```

## Class methods

### `.set_lock_timeout(timeout)`

Override the default lock timeout for the duration of the migration. For migrations that require AccessExclusive locks, this is limited to 750ms.

### `.set_statement_timeout(timeout)`

Override the default statement timeout for the duration of the migration. For migrations that require AccessExclusive locks, this is limited to 1500ms.

## Migration methods

### `#add_column(table, name, type, **kwargs)`
Adds a new column. Nandi will explicitly set the column to be NULL, as validating a new NOT NULL constraint can be very expensive on large tables and cause availability issues.

### `#add_foreign_key(table, target, column: nil, name: nil)`
Add a foreign key constraint. The generated SQL will include the NOT VALID parameter, which will prevent immediate validation of the constraint, which locks the target table for writes potentially for a long time. Use the separate #validate_constraint method, in a separate migration; this only takes a row-level lock as it scans through.

### `#add_index(table, fields, **kwargs)`
Adds a new index to the database.

Nandi will:

- add the `CONCURRENTLY` option, which means the change takes a less restrictive lock at the cost of not running in a DDL transaction
- use the `BTREE` index type which is the safest to create.

Because index creation is particularly failure-prone, and because we cannot run in a transaction and therefore risk partially applied migrations that (in a Rails environment) require manual intervention, Nandi Validates that, if there is a add_index statement in the migration, it must be the only statement.

### `#create_table(table) {|columns_reader| ... }`
Creates a new table. Yields a ColumnsReader object as a block, to allow adding columns.

Examples:

```rb
create_table :widgets do |t|
  t.text :foo, default: true
end
```

### `#remove_column(table, name, **extra_args)`
Remove an existing column.

### `#drop_constraint(table, name)`
Drops an existing constraint.

### `remove_not_null_constraint(table, column)`
Drops an existing NOT NULL constraint. Please not that this migration is not safely reversible; to enforce NOT NULL like behaviour, use a CHECK constraint and validate it in a separate migration.

### `#remove_index(table, target)`
Drop an index from the database.

Nandi will add the `CONCURRENTLY` option, which means the change takes a less restrictive lock at the cost of not running in a DDL transaction.
Because we cannot run in a transaction and therefore risk partially applied migrations that (in a Rails environment) require manual intervention, Nandi Validates that, if there is a remove_index statement in the migration, it must be the only statement.

### `#drop_table(table)`
Drops an existing table.

### `#irreversible_migration`
Raises `ActiveRecord::IrreversibleMigration` error.

## Configuration

Nandi can be configured in various ways, typically in an initializer:

```rb
Nandi.configure do |config|
  config.lock_timeout = 1_000
end
```

The configuration parameters are as follows.

### `access_exclusive_lock_timeout_limit` (Integer)

The maximum statement timeout for migrations that take an ACCESS EXCLUSIVE lock and therefore block all reads and writes. Default: 1500ms.

### `access_exclusive_statement_timeout_limit` (Integer)

The maximum lock timeout for migrations that take an ACCESS EXCLUSIVE lock and therefore block all reads and writes. Default: 750ms.

### `lock_timeout` (Integer)

The default lock timeout for migrations. Can be overridden by way of the `set_lock_timeout` class method in a given migration. Default: 750ms.

### `migration_directory` (String)

The directory for Nandi migrations. Default: `db/safe_migrations`

### `output_directory` (String)

The directory for output files. Default: `db/migrate`

### `renderer` (Class)

The rendering backend used to produce output. The only supported option at current is `Nandi::Renderers::ActiveRecord`, which produces ActiveRecord migrations.

### `statement_timeout` (Integer)

The default statement timeout for migrations. Can be overridden by way of the `set_statement_timeout` class method in a given migration. Default: 1500ms.

#post_process {|migration| ... }

Register a block to be called on output, for example a code formatter. Whatever is returned will be written to the output file.

```rb
config.post_process { |migration| MyFormatter.format(migration) }
```

#register_method(name, klass)

Register a custom DDL method.

Parameters:

`name` (Symbol) - The name of the method to create. This will be monkey-patched into Nandi::Migration.

`klass` (Class) — The class to initialise with the arguments to the method. It should define a `template` instance method which will return a subclass of Cell::ViewModel from the Cells templating library and a `procedure` method that returns the name of the method. It may optionally define a `mixins` method, which will return an array of `Module`s to be mixed into any migration that uses this method.


## Why Nandi?

You may have noticed a GIF of an adorable baby elephant above. This elephant is called Nandi, and she was the star of many an internal presentation slide here at GoCardless. Of course, Postgres is elephant-themed; but it is sometimes an angry elephant, motivating the creation of gems like this one. What better mascot than a harmless, friendly calf?

## Generate documentation

```sh
bundle exec yard
```

## Run tests

```sh
bundle exec rspec
```
