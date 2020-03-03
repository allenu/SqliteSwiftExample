# TODOs

- [ ] Clean up all the code
    - [ ] Remove print() statements
    - [ ] Remove commented code
    - [ ] Update README to explain what this is

- [ ] Make dataSource generic instead of using Person, use <T>

- [x] Get rid of maxCacheWindowSize and just keep track of the largest window size encountered
      and when shifting window around try to maintain it

- [ ] Handle case where we load items arbitrarily at an offset but it returns NOTHING
    - if it's before our current position... collapse ?
    - if it's after our current position... collapse and try re-fetching?
    - best solution might be to just reset?

- [ ] Add new tests
    - [x] Something that deletes a random entry
    - [ ] Just get rid of Sqlite and have a simulated Database source

- [ ] More update logic
    - [x] if we delete items from the cache window, fetch items towards end to keep it same size
    - [ ] Make setting the searchFilter trigger a notification to reload the database
    - [x] Make it so that the tableView allows insert if it's tacking onto the end of the current window *AND* we're "viewing"
          towards the end of the window ... how do we indicate that we are looking at the tail end of the window, though?
    - [x] Make UI auto scroll to end if it detects new entries added to window ?

    - [ ] Tweak the cache window size against the visible rect for optimum loading of new entries
        - [ ] Consider if we even need a "max cache size"
            - why not just cache enough to cover the current window requested by setCacheWindow
            - or just enough to cover it and maybe alpha * N on either side, where alpha is some percentage, like 20%

    - [x] Cache Person objects in DatabaseCacheWindow itself
        - [x] refresh contents when forced to via updateCacheIfNeeded
        - [x] remove from cache if detected in removeIdentifiers

    - [x] handle insertion updates
        - if we insert items on the fly, have it insert into the cachedWindow if it matches query
        - check with databaseManager if it matches current searcrFilter
        - insert into current cache window IF
            - matches current searchFilter
            - identifier is greater than first one OR cache is empty
              - AND identifier is less than Nth in the list (not necessarily the last one) OR cache is empty
            - identifier is not yet in the cache
        - find where in list of items it would go
          - may want to cache all current People to make it easier to find where to place it in cache list
        - drop off last item in the cache
        - do insert() operation to make it visible
    - [ ] Handle cases where we do both update a few items, delete a few items, and insert a few items.
        - do updates first
        - then do inserts
        - then do deletes

    - [x] BUG: It's possible to delete everything but have the wrong total items count in numKnownItems
        - it appears we aren't accounting for all deleted items
        - OR we're probably doing our math wrong because windowSize is zero...

    - [x] BUG: Delet all items
        - next, insert a new item and scroll
        -> CRASH

    - [ ] BUG: Delete all rows by entering nothing in delete like text field
        -> ugly debug spew

- [x] Add notifiation when items are updated

- [ ] Write new setCacheWindow(position:, size:)
    - [x] Make it functional
        - start with num known items, windowOffset, windowSize AND new requested windowOffset, new requested windowSize AND actual
          new windowSize (based on what we were able to fetch)
        - returns new known items, windowOffset, windowSize and TableOperations
    - [x] Move DataWindowCache into its own class and have it delegate to its DataWindowCacheDataSource
    - [x] Have TableView use DataWindowCacheDataSource as its DataSource -- or else route it from ViewController to it

- [x] Add a search filter
    - [x] Add text field that triggers search on each char typed
    - [x] Update DatabaseManager
        - [x] add resetCache() which just sets n_tail = 0, n_window = 0, n_head = 0 and clears cached identifiers

        - [x] add setCacheWindow(position:, cachedWindowSize:)
            - will attempt to position the cache pointer to row "position"
            - will set n_tail to 0 at first and any scroll *up* will load more entries as needed
            - will set n_head to 0 as well
            - [ ] if no contents at position, will attempt to get the first cachedWindowSize entries before that position

            - will do the math to figure out if there is overlap between the new position and old one and only fetch enough
              to cover new position
              - [x] Make it still return the tableView insert/update/remove operations required

        - [x] Add "searchFilter" text var which is used for the next query
        - [x] add currentQuery: QueryType 
            - [x] Make it so when searchFilter is set, we make it peopleTable.filter(nameColumn == "string")
            - [x] Make it so that when searchFilter is empty, we just use peopleTable

- [x] when you scroll by grabbing the scroll bar, the cache window does not keep up
    - we need to make it support an arbitrary "cache at row N"; but what does that mean exactly in the context
      of a SQL search? we'd need to be able to know how many results there are and zero in on that row
      - [x] Consider reporting the *true* number of rows in the query, if it's even possible ? it might be costly
            as a SQL query to do a COUNT() of all entries that match a given query

- [-] Make fetch request on a background thread for shifting window -- and ensure SQLite accesses are always on same thread.
      When fetch is done, update the window appropriately. If a fetch request occurs while we're still in the middle of
      a fetch, just drop it.

- [x] Bug: when you add a new person using the "Add Person" button and then scroll the table view, SQLite crashes
    - It's probably because the row iterator doesn't like the fact that we inserted a new row. Maybe we need to
      refresh the row iterator somehow but maintain our position in it.

- [x] Design how we are to handle a sorted list of identifiers for all the people in-mem while items are being
      inserted and deleted from the SQLite table.

      We might want to have an incrementing counter for *new* row in the table. Whenever a new is inserted,
      we can re-create the row iterator and make sure to start with a filter where the incrementing counter is
      greater than the last one we got.

      We could also just re-create the row iterator whenever we fetch. There's no need to only do it when we
      mutate the table.

- [x] Add a "Delete Person" button

    - Should delete from table view
    - Should delete from database

- [x] Sort rows by an arbitrary column: (Age or weight or name?)
    - Handle deletion
    - Handle insert (which could insert anywhere arbitrarily)

- [x] Switch tableView to be NSView-based instead of cell-based. This way we'll get the benefits of lazy-loading.

