//
//  DatabaseManager.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/23/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import SQLite

enum AdjustTableCommand {
    case none // TODO: get rid of
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

class DatabaseManager {
    let fileUrl: URL
    
    let connection: Connection
    
    let peopleTable: Table
    let idColumn = Expression<String>("identifier")
    let nameColumn = Expression<String>("name")
    let weightColumn = Expression<Int64>("weight")
    let ageColumn = Expression<Int64>("age")
    
    var sortedPeopleIdentifiers: [String] = []
    var fetchedPeople: [String : Person] = [:]
    var peopleRowIterator: RowIterator!
    
    var currentQuery: QueryType {
        if let searchFilter = searchFilter {
            return peopleTable.filter(nameColumn.like("%\(searchFilter)%"))
        } else {
            return peopleTable
        }
    }
    
    // Assume true until it's not
    var hasMoreRows = true
    
    var nextRowIndex: Int = 0
    
    // New caching system
    var cachedWindowSize: Int = 20
    var n_window: Int = 0
    var n_head: Int = 0
    var n_tail: Int = 0
    // Sorted list of identifiers in current window
    var cachedIdentifiers: [String] = [] // TODO: Could also store full entries in memory?
    
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
            peopleRowIterator = try! connection.prepareRowIterator(peopleTable.select(idColumn))
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
            
            let person = Person(identifier: uuid, name: "\(row) - \(name)", weight: weight, age: age)
            print("Creating person: \(person)")
            insert(person: person)
            
            // Wait a second
            usleep(50 * 1000)
        }
        
        // Assume we could fetch more...
        hasMoreRows = true
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
    
    func numFetchedPeople() -> Int {
        return sortedPeopleIdentifiers.count
    }
    
    func person(at row: Int) -> Person? {
        if row < sortedPeopleIdentifiers.count {
            let identifier = sortedPeopleIdentifiers[row]
            return person(for: identifier)
        } else {
            return nil
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
    
    // Fetch more people into the list
    func fetchPeople(numPeople: Int) -> Int {
        var numFetched: Int = 0
        
        while numFetched < numPeople {
            if let personIdentifier = peopleRowIterator.next() {
                sortedPeopleIdentifiers.append(personIdentifier[idColumn])
                numFetched = numFetched + 1
            } else {
                // No more
                hasMoreRows = false
                break
            }
        }
        
        return numFetched
    }
    
    
    // New system
    func numFuzzyItems() -> Int {
        let n = n_tail + n_window + n_head
        print("numFuzzyItems = \(n)")
        return n
    }
    
    func effectiveWindowStartIndex() -> Int {
        return n_tail
    }
    
    func effectiveWindowEndIndex() -> Int {
        return n_tail + n_window
    }
    
    func cachedPerson(at effectiveRow: Int) -> Person? {
        // Figure out actual index in cache
        let cacheIndex = effectiveRow - n_tail
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
    
    func prefetchCache(cachedWindowSize: Int) {
        self.cachedWindowSize = cachedWindowSize
        n_head = 0
        n_tail = 0
        
        // Fetch window size elements from database...
        cachedIdentifiers = []
        do {
            for row in try connection.prepare(currentQuery.limit(cachedWindowSize)) {
                let identifier = row[idColumn]
                cachedIdentifiers.append(identifier)
            }
        } catch {
            print("Error getting people \(error)")
        }
        
        n_window = cachedIdentifiers.count
    }
    
    func shiftCacheWindow(up n: Int) -> (Int, AdjustTableCommand) {
//        print("shiftCacheWindow(up: \(n) )")
        
        // Try to fetch n rows *before* the first cached item
        let query: QueryType
        
        if let lastItemIdentifier = cachedIdentifiers.first {
            query = currentQuery.filter(idColumn < lastItemIdentifier).order(idColumn.desc).limit(n)
        } else {
            // We don't have any entries at all yet... so just search for ALL items
            query = currentQuery.order(idColumn.desc).limit(n)
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
        
//        print("prepending \(prependedIdentifiers.count) items")
        
        // Drop items at END of cache so we always have a max window size
        let numOverflowItems = max(0, cachedIdentifiers.count + prependedIdentifiers.count - cachedWindowSize)
        cachedIdentifiers.removeLast(numOverflowItems)
        
        cachedIdentifiers.insert(contentsOf: prependedIdentifiers, at: 0)
        
        // Head should get bigger with whatever got pushed out of window INTO the head
        n_head = n_head + numOverflowItems
        
        let adjustTableCommand: AdjustTableCommand
        let carriedItems = min(n_tail, numOverflowItems)
        if carriedItems < numOverflowItems {
            // We carried items from the ether at the tail, so we need to signal to the caller that we
            // must insert that many entries into the tail
            let insertedCount = numOverflowItems - carriedItems
            adjustTableCommand = .insert(at: 0, count: insertedCount)
            // TODO: we should also update carriedItems along with the insert...
        } else {
            adjustTableCommand = .update(at: n_tail - carriedItems, count: carriedItems)
        }
        // Tail should get smaller from whatever we had to carry
        n_tail = n_tail - carriedItems

        n_window = cachedIdentifiers.count // n_window should always be cachedIdentifiers size
        
//        print("cache window: \(n_tail) to \(n_tail + n_window) ")
        
        // We've shifted up by an amount, so return that
        return (numOverflowItems, adjustTableCommand)
    }
    
    func shiftCacheWindow(down n: Int) -> (Int, AdjustTableCommand) {
//        print("shiftCacheWindow(down: \(n) )")
        
        // Try to fetch n rows beyond the last item
        let query: QueryType
        
        if let lastItemIdentifier = cachedIdentifiers.last {
            query = currentQuery.filter(idColumn > lastItemIdentifier).limit(n)
        } else {
            // We don't have any entries at all yet... so just search for ALL items
            query = currentQuery.limit(n)
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
        
//        print("appending \(appendedIdentifiers.count) items")
        
        // Remove items at start so we always have a max window size
        let numOverflowItems = max(0, cachedIdentifiers.count + appendedIdentifiers.count - cachedWindowSize)
        
        cachedIdentifiers.removeFirst(numOverflowItems)
        cachedIdentifiers.append(contentsOf: appendedIdentifiers)
        
        // Recalculate things
        let old_n_head_index = n_tail + n_window
        n_tail = n_tail + numOverflowItems // tail picks up whatever was pushed OUT of window out the back
        n_window = cachedIdentifiers.count // n_window should always be cachedIdentifiers size
        
        // We've pulled items from the head, so reduce it as necessary
        let adjustTableCommand: AdjustTableCommand
        let numNewItems = appendedIdentifiers.count
        if numNewItems > n_head {
            // We carried items from the ether, so we need to signal to the caller that we
            // must insert that many entries
            let insertedCount = numNewItems - n_head
            adjustTableCommand = .insert(at: old_n_head_index, count: insertedCount)
            
            // Head is now empty since we pulled more than what was in there to begin with
            n_head = 0
        } else {
            //adjustTableCommand = .none
            adjustTableCommand = .update(at: old_n_head_index, count: numNewItems)
            n_head = n_head - numNewItems
        }

//        print("cache window: \(n_tail) to \(n_tail + n_window) ")
        
        // We've shifted down by an amount, so return that
        return (numOverflowItems, adjustTableCommand)
    }
    
    func resetCache() {
        n_head = 0
        n_window = 0
        n_tail = 0
        cachedIdentifiers = []
    }
    
    func updateCacheWindow(position: Int, cacheWindowSize: Int) {
        
    }

}
