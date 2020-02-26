# TODOs

- [ ] Make fetch request on a background thread for shifting window -- and ensure SQLite accesses are always on same thread.
      When fetch is done, update the window appropriately. If a fetch request occurs while we're still in the middle of
      a fetch, just drop it.

- [ ] Bug: when you add a new person using the "Add Person" button and then scrol the table view, SQLite crashes
    - It's probably because the row iterator doesn't like the fact that we inserted a new row. Maybe we need to
      refresh the row iterator somehow but maintain our position in it.

- [ ] Design how we are to handle a sorted list of identifiers for all the people in-mem while items are being
      inserted and deleted from the SQLite table.

      We might want to have an incrementing counter for *new* row in the table. Whenever a new is inserted,
      we can re-create the row iterator and make sure to start with a filter where the incrementing counter is
      greater than the last one we got.

      We could also just re-create the row iterator whenever we fetch. There's no need to only do it when we
      mutate the table.

- [ ] Add a "Delete Person" button

    - Should delete from table view
    - Should delete from database

- [ ] Sort rows by an arbitrary column: (Age or weight or name?)
    - Handle deletion
    - Handle insert (which could insert anywhere arbitrarily)

- [ ] Switch tableView to be NSView-based instead of cell-based. This way we'll get the benefits of lazy-loading.

