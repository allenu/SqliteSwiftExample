//
//  DatabaseManager.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/23/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import SQLite

enum TableOperation {
    case none
    case reload
    case update(at: Int, count: Int)
    case insert(at: Int, count: Int)
    case remove(at: Int, count: Int)
}

struct Person {
    let identifier: String
    var name: String
    var weight: Int64
    var age: Int64
    
    static let identifierPropertyKey = "identifier"
    static let namePropertyKey = "name"
    static let weightPropertyKey = "weight"
    static let agePropertyKey = "age"
}

struct CacheWindowState {
    let numKnownItems: Int
    let windowOffset: Int
    let windowSize: Int
}

struct GrowCacheWindowResult {
    let cacheWindowState: CacheWindowState
    let tableOperations: [TableOperation]
}

// Attempt to grow a cache in reverse by delta items (negative delta value) or forwards (positive delta value).
// numItemsFetched indicates how many we were actually able to grow in that direction.
func growCacheWindow(from oldCacheWindowState: CacheWindowState, delta: Int, numItemsFetched: Int) -> GrowCacheWindowResult {
    if delta == 0 {
        assertionFailure("Must not call with delta == 0")
    }
    
    var tableOperations: [TableOperation] = []
    
    // Growing backwards
    var numItemsDeleted: Int = 0
    var numItemsInserted: Int = 0
    let newWindowOffset: Int
    if delta < 0 {
        let desiredItemsToFetch = -delta
        // We only expect to fetch either how many items are actual before our offset or the number requested,
        // whichever is smaller
        let numItemsExpected = min(desiredItemsToFetch, oldCacheWindowState.windowOffset)
        
        if numItemsFetched < numItemsExpected {
            // We fetched fewer than we expected, so this means we will have to delete some items
            numItemsDeleted = numItemsExpected - numItemsFetched
            
            let updatePosition = oldCacheWindowState.windowOffset - numItemsFetched
            let deletePosition = updatePosition - numItemsDeleted
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
            tableOperations.append(.remove(at: deletePosition, count: numItemsDeleted))
            
            print("Need to delete items: \(numItemsDeleted)")
            
            // Move window down to delete position
            newWindowOffset = deletePosition
        } else if numItemsFetched > numItemsExpected {
            // We fetched more than we expected, so we need to insert new items
            numItemsInserted = numItemsFetched - numItemsExpected
            
            let updatePosition = oldCacheWindowState.windowOffset - numItemsExpected
            let insertPosition = updatePosition - numItemsInserted
            tableOperations.append(.update(at: updatePosition, count: numItemsExpected))
            tableOperations.append(.insert(at: insertPosition, count: numItemsInserted))

            newWindowOffset = insertPosition
        } else {
            // We fetched exactly the number we expected
            let updatePosition = oldCacheWindowState.windowOffset - numItemsFetched
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
            newWindowOffset = oldCacheWindowState.windowOffset - numItemsExpected
        }
    } else {
        let desiredItemsToFetch = delta

        // We only expect to fetch at most however many there are beyond the end of our window
        let numItemsBeyondWindow = oldCacheWindowState.numKnownItems - (oldCacheWindowState.windowOffset + oldCacheWindowState.windowSize)
        let numItemsExpected = min(desiredItemsToFetch, numItemsBeyondWindow)
        
        let updatePosition = oldCacheWindowState.windowOffset + oldCacheWindowState.windowSize
        if numItemsFetched < numItemsExpected {
            // We will need to delete some, but do it beyond where we just fetched
            numItemsDeleted = numItemsExpected - numItemsFetched
            
            let deletePosition = updatePosition + numItemsFetched
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
            tableOperations.append(.remove(at: deletePosition, count: numItemsDeleted))
        } else if numItemsFetched > numItemsExpected {
            // We need to insert some new ones at end of entire list
            numItemsInserted = numItemsFetched - numItemsExpected
            
            // Insert past the point where we expected
            let insertPosition = updatePosition + numItemsExpected
            tableOperations.append(.update(at: updatePosition, count: numItemsExpected))
            tableOperations.append(.insert(at: insertPosition, count: numItemsInserted))
        } else {
            // We fetched exactly what we expected.
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
        }
        
        // Since we are growing at the end of our window, no need to update windowOffset
        newWindowOffset = oldCacheWindowState.windowOffset
    }
    
    let newWindowSize = oldCacheWindowState.windowSize + numItemsFetched
    let newNumKnownItems  = oldCacheWindowState.numKnownItems - numItemsDeleted + numItemsInserted
    let newCacheWindowState = CacheWindowState(numKnownItems: newNumKnownItems, windowOffset: newWindowOffset, windowSize: newWindowSize)
    
    return GrowCacheWindowResult(cacheWindowState: newCacheWindowState, tableOperations: tableOperations)
}

class DatabaseManager {
    static let dataDidChangeNotification = NSNotification.Name("DatabaseManagerDataDidChange")
    
    let fileUrl: URL
    
    let connection: Connection
    
    let peopleTable: Table
    let idColumn = Expression<String>("identifier")
    let nameColumn = Expression<String>("name")
    let weightColumn = Expression<Int64>("weight")
    let ageColumn = Expression<Int64>("age")
    
    var nextRowIndex: Int = 0
    
    // New caching system
    var currentQuery: QueryType {
        if let searchFilter = searchFilter {
            return peopleTable.filter(nameColumn.like("%\(searchFilter)%"))
        } else {
            return peopleTable
        }
    }
    
    // Sorted list of identifiers in current window
    var cachedIdentifiers: [String] = [] // TODO: Could also store full entries in memory?
    var cacheWindowState = CacheWindowState(numKnownItems: 0, windowOffset: 0, windowSize: 0)
    
    var searchFilter: String?

    init?(fileUrl: URL) {
        self.fileUrl = fileUrl
        
        var connection: Connection?
        do {
            connection = try Connection(fileUrl.path)
        } catch {
            connection = nil
        }
    
        if let connection = connection {
            self.connection = connection
            peopleTable = Table("people")
        } else {
            return nil
        }
    }
    
    func setupTables() {
        do {
            try connection.run(peopleTable.create { t in
                t.column(idColumn, primaryKey: true)
                t.column(nameColumn)
                t.column(weightColumn)
                t.column(ageColumn)
            })
        } catch {
            // Maybe already created table?
        }
    }
    
    func generateRows(numRows: Int) {
        Array(0..<numRows).forEach { row in
            // let uuid = UUID().uuidString
            let uuid = String(format: "%05d", nextRowIndex)
            nextRowIndex = nextRowIndex + 1
            let names = [
                "John Paul",
                "Paul",
                "George Smith",
                "Ringo",
                "Alice",
                "Rina"
            ]
            let name = names[ (Int(arc4random()) % names.count) ]
            let weight = 100 + Int64(arc4random() % 50)
            let age = 10 + Int64(arc4random() % 40)
            
            let person = Person(identifier: uuid, name: "\(nextRowIndex) - \(name)", weight: weight, age: age)
            print("Creating person: \(person)")
            insert(person: person)
            
            // Wait a second
            usleep(50 * 1000)
        }
    }
    
    func insertPerson(name: String) {
        let uuid = String(format: "%05d", nextRowIndex)
        nextRowIndex = nextRowIndex + 1
        let person = Person(identifier: uuid, name: "\(nextRowIndex) - \(name)", weight: 69, age: 42)
        insert(person: person)
    }
    
    func insert(person: Person) {
        let insert = peopleTable.insert(
            idColumn <- person.identifier,
            nameColumn <- person.name,
            weightColumn <- person.weight,
            ageColumn <- person.age)
        
        do {
            let rowid = try connection.run(insert)
            print("inserted row \(rowid)")
        } catch {
            print("Failed to insert person with identifier \(person.identifier) -- may already exist? error: \(error)")
        }
    }
    
    func deleteLike(name: String) {
        let deleteFilter = peopleTable.filter(nameColumn.like("%\(name)%"))
        
        do {
            // Get all identifiers that match -- but only do first 10 ?
            
            let allRowsToDelete = try connection.prepare(deleteFilter)
            var removedIdentifiers: [String] = []
            for row in allRowsToDelete {
                removedIdentifiers.append(row[idColumn])
            }
            
            if try connection.run(deleteFilter.delete()) > 0 {
                print("deleted \(name) items")
                
                NotificationCenter.default.post(name: DatabaseManager.dataDidChangeNotification, object: self, userInfo: ["removedIdentifiers" : removedIdentifiers])

            } else {
                print("no items found")
            }
        } catch {
            print("delete failed: \(error)")
        }
    }
    
    func person(for identifier: String) -> Person? {
        let query = peopleTable.filter(idColumn == identifier)
        do {
            let result = try connection.prepare(query)
            if let personRow = result.makeIterator().next() {
                let person = Person(identifier: personRow[idColumn],
                                    name: personRow[nameColumn],
                                    weight: personRow[weightColumn],
                                    age: personRow[ageColumn])
                return person
            } else {
                print("Error fetching person row \(identifier)")
            }
        } catch {
            print("Error loading person \(identifier)")
        }
        
        return nil
    }
    
    // New system
    func numItems() -> Int {
        return cacheWindowState.numKnownItems
    }
    
    func effectiveWindowStartIndex() -> Int {
        return cacheWindowState.windowOffset
    }
    
    func effectiveWindowEndIndex() -> Int {
        return cacheWindowState.windowOffset + cacheWindowState.windowSize
    }
    
    func cachedPerson(at effectiveRow: Int) -> Person? {
        // Figure out actual index in cache
        let cacheIndex = effectiveRow - cacheWindowState.windowOffset
        if cacheIndex < 0 {
//            print("cacheIndex < 0: effectiveRow \(effectiveRow) - n_tail \(n_tail) = \(cacheIndex)")
            return nil
        } else if cacheIndex >= cachedIdentifiers.count {
//            print("cacheIndex < \(cachedIdentifiers.count): effectiveRow \(effectiveRow) - n_tail \(n_tail) = \(cacheIndex)")
            return nil
        } else {
            let identifier = cachedIdentifiers[cacheIndex]
            return person(for: identifier)
        }
    }
    
    // Note: "position" could be a negative number if we are trying to see if there are items
    // before the first item.
    func setCacheWindow(newOffset: Int, newSize: Int) -> [TableOperation] {
        let maxCacheWindowSize = 80
        let newSize = min(maxCacheWindowSize, newSize)
//        assert(newSize < maxCacheWindowSize)
        
        let oldCacheWindowEnd = cacheWindowState.windowOffset + cacheWindowState.windowSize
        let newCacheWindowEnd = newOffset + newSize
        
        let hasNoCacheData = cacheWindowState.windowSize == 0
        
        if newOffset < cacheWindowState.windowOffset && newCacheWindowEnd > cacheWindowState.windowOffset && newCacheWindowEnd < oldCacheWindowEnd {
            // Window moved backwards but overlaps old window
            
            // Fetch backwards
            let query: QueryType
            
            // We only need to fetch enough rows to shift window up beyond where it already is
            let numItemsToFetch = cacheWindowState.windowOffset - newOffset
            
            if let lastItemIdentifier = cachedIdentifiers.first {
                query = currentQuery.filter(idColumn < lastItemIdentifier).order(idColumn.desc).limit(numItemsToFetch)
            } else {
                // We don't have any entries at all yet... so just search for ALL items
                query = currentQuery.order(idColumn.desc).limit(numItemsToFetch)
            }
            var prependedIdentifiers: [String] = []
            do {
                let result = try connection.prepare(query)
                // Insert in reverse order by inserting each item at 0
                while let personRow = result.makeIterator().next() {
                    prependedIdentifiers.insert(personRow[idColumn], at: 0)
                }
            } catch {
                print("Error loading person row")
            }
            let numItemsFetched = prependedIdentifiers.count
            
            let delta = newOffset - cacheWindowState.windowOffset
            let result = growCacheWindow(from: cacheWindowState, delta: delta, numItemsFetched: numItemsFetched)
            
            cachedIdentifiers.insert(contentsOf: prependedIdentifiers, at: 0)
            cacheWindowState = result.cacheWindowState
            
            let numCacheItemsOverLimit = cachedIdentifiers.count - maxCacheWindowSize
            if numCacheItemsOverLimit > 0 {
                // Remove last items if our cache gets too large
                _ = cachedIdentifiers.removeLast(numCacheItemsOverLimit)
                cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems, windowOffset: cacheWindowState.windowOffset, windowSize: cachedIdentifiers.count)
            }

            return result.tableOperations
            
        } else if newOffset >= cacheWindowState.windowOffset && newOffset < oldCacheWindowEnd && newCacheWindowEnd > oldCacheWindowEnd || hasNoCacheData {
            // Window moved forwards but overlaps old window
            
            // Fetch forwards from oldCacheWindowEnd
            
            // We only need to fetch enough rows to shift window up beyond where it already is
            let numItemsToFetch = newCacheWindowEnd - oldCacheWindowEnd
            if numItemsToFetch > 0 {
                // Try to fetch numItemsToFetch rows beyond the last item
                let query: QueryType
                
                if let lastItemIdentifier = cachedIdentifiers.last {
                    query = currentQuery.filter(idColumn > lastItemIdentifier).limit(numItemsToFetch)
                } else {
                    // We don't have any entries at all yet... so just search for ALL items
                    query = currentQuery.limit(numItemsToFetch)
                }

                var appendedIdentifiers: [String] = []
                do {
                    let result = try connection.prepare(query)
                    while let personRow = result.makeIterator().next() {
                        appendedIdentifiers.append(personRow[idColumn])
                    }
                } catch {
                    print("Error loading person row")
                }
                let numItemsFetched = appendedIdentifiers.count
                
                let delta = newCacheWindowEnd - oldCacheWindowEnd
                let result = growCacheWindow(from: cacheWindowState, delta: delta, numItemsFetched: numItemsFetched)
                
                cachedIdentifiers.append(contentsOf: appendedIdentifiers)
                cacheWindowState = result.cacheWindowState
                let numCacheItemsOverLimit = cachedIdentifiers.count - maxCacheWindowSize
                if numCacheItemsOverLimit > 0 {
                    // Remove first items if our cache gets too large
                    _ = cachedIdentifiers.removeFirst(numCacheItemsOverLimit)
                    cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems, windowOffset: cacheWindowState.windowOffset + numCacheItemsOverLimit, windowSize: cachedIdentifiers.count)
                }
                
                return result.tableOperations
            } else {
                // We had nothing to fetch, so do nothing
                return []
            }
        } else {
            // No overlap, so we are arbitrarily positioning it somewhere
            
            // Ensure we don't go below zero for these cases
            let adjustedNewOffset = max(0, newOffset)
            
            // Try to fetch items there
            let query = currentQuery.limit(newSize, offset: adjustedNewOffset)
            var newIdentifiers: [String] = []
            do {
                let result = try connection.prepare(query)
                while let personRow = result.makeIterator().next() {
                    newIdentifiers.append(personRow[idColumn])
                }
            } catch {
                print("Error loading person row")
            }
            let numItemsFetched = newIdentifiers.count
            
            cachedIdentifiers = newIdentifiers
            
            if numItemsFetched == 0 {
                // Uh oh -- NYI
                return []
            } else {
                let numItemsExpected = min(cacheWindowState.numKnownItems - adjustedNewOffset, newSize)
                let numKnownItems: Int
                if numItemsFetched < numItemsExpected {
                    // Got fewer than expected, so do delete
                    
                    print("Got fewer than expected, so do delete")
                    
                    numKnownItems = adjustedNewOffset + numItemsFetched
                    let numItemsDeleted = numItemsExpected - numItemsFetched
                    
                    let operations: [TableOperation] = [
                        .remove(at: adjustedNewOffset + numItemsFetched, count: numItemsDeleted)
                    ]
                    
                    cacheWindowState = CacheWindowState(numKnownItems: numKnownItems, windowOffset: adjustedNewOffset, windowSize: numItemsFetched)
                    return operations
                } else if numItemsFetched > numItemsExpected {
                    // Got more than expected
                    print("Got more than expected")
                    
                    numKnownItems = adjustedNewOffset + numItemsFetched
                    let numItemsInserted = numItemsFetched - numItemsExpected
                    
                    let operations: [TableOperation] = [
                        .insert(at: adjustedNewOffset + numItemsExpected, count: numItemsInserted)
                    ]
                    
                    cacheWindowState = CacheWindowState(numKnownItems: numKnownItems, windowOffset: adjustedNewOffset, windowSize: numItemsFetched)
                    return operations

                } else {
                    // Got everything we expected
                    print("Got everything we expected: adjustedNewOffset: \(adjustedNewOffset) numItemsFetched \(numItemsFetched)")
                    
                    assert(adjustedNewOffset >= 0)
                    
                    if numItemsFetched > 0 {
                        let operations: [TableOperation] = [
                            .update(at: adjustedNewOffset, count: numItemsFetched)
                        ]
                        
                        cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems, windowOffset: adjustedNewOffset, windowSize: numItemsFetched)
                        return operations
                    } else {
                        // Nothing fetched
                        return []
                    }
                }
            }
        }
    }
    
    func resetCache() {
        cacheWindowState = CacheWindowState(numKnownItems: 0, windowOffset: 0, windowSize: 0)
        cachedIdentifiers = []
    }
    
    func updateCacheIfNeeded(updatedIdentifiers: [String],
                             insertedIdentifiers: [String],
                             removedIdentifiers: [String]) -> [TableOperation] {
        
        let updatedIndexes: [Int] = updatedIdentifiers.compactMap { identifier in
            return cachedIdentifiers.firstIndex(where: { $0 == identifier})
        }
        
        let unsortedDeletedIndexes: [Int] = removedIdentifiers.compactMap { identifier in
            return cachedIdentifiers.firstIndex(where: { $0 == identifier })
        }
        let deletedIndexes = unsortedDeletedIndexes.sorted()
        
        // TODO: Handle both update, insert, and delete somehow. We need to be very smart about
        // the order in which we do it ...
        
        let tableOperations: [TableOperation]
        if deletedIndexes.count > 0 {
            
            // Remove those items in reverse order from the cachedIdentifiers
            deletedIndexes.reversed().forEach { index in
                cachedIdentifiers.remove(at: index)
            }
            cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems - deletedIndexes.count,
                                                windowOffset: cacheWindowState.windowOffset,
                                                windowSize: cacheWindowState.windowSize - deletedIndexes.count)
            
            let deleteOperations: [TableOperation] = deletedIndexes.reversed().map { deletedIndex in
                return TableOperation.remove(at: cacheWindowState.windowOffset + deletedIndex, count: 1)
            }
            
            // Try to grow the cache some more
            let newSize = cacheWindowState.windowSize + deletedIndexes.count
            let insertOperations = setCacheWindow(newOffset: cacheWindowState.windowOffset, newSize: newSize)
            
            tableOperations = deleteOperations + insertOperations
        } else if updatedIndexes.count > 0 {
            tableOperations = updatedIndexes.map { updatedIndex in
                return TableOperation.update(at: cacheWindowState.windowOffset + updatedIndex, count: 1)
            }
        } else {
            // TODO: if anything inserted ...
            // - see if it would appear in the range of our view of rows
            // - if so, insert it appropriately
            
            tableOperations = []
        }
        
        return tableOperations
    }
    
    func updateLike(name: String) {
        // Find all the Pauls in the cache and add a random number to them
        
        // Update all Pauls and update them and record that it was updated
        let updatedIdentifiers: [String] = cachedIdentifiers.compactMap { identifier in
            if let person = person(for: identifier) {
                if person.name.lowercased().contains(name.lowercased()) {
                    // Update this
                    let randomValue = arc4random() % 10
                    let newName = "\(person.name) \(randomValue)"
                    let paulQuery = peopleTable.filter(idColumn == identifier)
                    
                    do {
                        if try connection.run(paulQuery.update(nameColumn <- newName)) > 0 {
                            print("updated alice")
                        } else {
                            print("alice not found")
                        }
                        
                        return identifier
                    } catch {
                        print("Couldn't update paul \(person.name)")
                    }
                }
            }
            
            return nil
        }
        
        // Post the notification
        NotificationCenter.default.post(name: DatabaseManager.dataDidChangeNotification, object: self, userInfo: ["updatedIdentifiers" : updatedIdentifiers])
    }
        
}
