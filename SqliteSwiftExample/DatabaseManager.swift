//
//  DatabaseManager.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/23/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation
import SQLite

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
    static let dataDidChangeNotification = NSNotification.Name("DatabaseManagerDataDidChange")
    static let dataDidReloadNotification = NSNotification.Name("DatabaseManagerDataDidReload")
    
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
    
    var searchFilter: String? {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: DatabaseManager.dataDidReloadNotification, object: self)
            }
        }
    }

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
    
    func searchFilterContains(person: Person) -> Bool {
        if let searchFilter = searchFilter {
            if searchFilter.isEmpty {
                return true
            } else {
                return person.name.lowercased().contains(searchFilter.lowercased())
            }
        } else {
            return true
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
                "Alice",
                "Bob",
                "Carol",
                "Dan",
                "Eve",
                "Frank"
            ]
            let firstName = names[ (Int(arc4random()) % names.count) ]
            let lastName = names[ (Int(arc4random()) % names.count) ]
            let weight = 100 + Int64(arc4random() % 50)
            let age = 10 + Int64(arc4random() % 40)
            
            let person = Person(identifier: uuid, name: "\(nextRowIndex) - \(firstName) \(lastName)", weight: weight, age: age)
            insert(person: person)
            
            // Wait a second
            usleep(80 * 1000)
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
//            print("inserted row \(rowid)")
            
            // Announce it
            DispatchQueue.main.async {
                let insertedIdentifiers: [String] = [ person.identifier ]
                NotificationCenter.default.post(name: DatabaseManager.dataDidChangeNotification, object: self, userInfo: ["insertedIdentifiers" : insertedIdentifiers])
            }
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
                print("deleted items matching \(name)")
                
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

    func updateLike(name: String) {
        // Find all the Pauls in the cache and add a random number to them
        
        let updateFilter = peopleTable.filter(nameColumn.like("%\(name)%"))
        
        var updatedIdentifiers: [String] = []
        do {
            let allRowsToUpdate = try connection.prepare(updateFilter)
            for row in allRowsToUpdate {
                updatedIdentifiers.append(row[idColumn])
            }
        } catch {
            print("Couldn't update rows")
        }
            
        updatedIdentifiers.forEach { identifier in
            if let person = person(for: identifier) {
                if person.name.lowercased().contains(name.lowercased()) {
                    // Update this
                    let randomValue = arc4random() % 10
                    let newName = "\(person.name) \(randomValue)"
                    let paulQuery = peopleTable.filter(idColumn == identifier)
                    
                    do {
                        if try connection.run(paulQuery.update(nameColumn <- newName)) > 0 {
                            print("updated entries")
                        } else {
                            print("entries not found to update")
                        }
                    } catch {
                        print("Couldn't update paul \(person.name)")
                    }
                }
            }
        }
        
        // Post the notification
        NotificationCenter.default.post(name: DatabaseManager.dataDidChangeNotification, object: self, userInfo: ["updatedIdentifiers" : updatedIdentifiers])
    }
}

extension DatabaseManager: DatabaseCacheWindowItemProvider {
    typealias ItemType = Person
    
    func queryContains(item: ItemType) -> Bool {
        return searchFilterContains(person: item)
    }
    
    func item(for identifier: IdentifierType) -> ItemType? {
        return person(for: identifier)
    }
    
    func itemsBefore(identifier: IdentifierType?, limit: Int) -> [IdentifierType] {
        let query: QueryType
        
        if let identifier = identifier {
            query = currentQuery.filter(idColumn < identifier).order(idColumn.desc).limit(limit)
        } else {
            query = currentQuery.order(idColumn.desc).limit(limit)
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
        return prependedIdentifiers
    }
    
    func itemsAfter(identifier: IdentifierType?, limit: Int) -> [IdentifierType] {
        let query: QueryType
        
        if let identifier = identifier {
            query = currentQuery.filter(idColumn > identifier).limit(limit)
        } else {
            // We don't have any entries at all yet... so just search for ALL items
            query = currentQuery.limit(limit)
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
        return appendedIdentifiers
    }
    
    func items(at index: Int, limit: Int) -> [IdentifierType] {
        // Try to fetch items there
        let query = currentQuery.limit(limit, offset: index)
        var newIdentifiers: [String] = []
        do {
            let result = try connection.prepare(query)
            while let personRow = result.makeIterator().next() {
                newIdentifiers.append(personRow[idColumn])
            }
        } catch {
            print("Error loading person row")
        }
        return newIdentifiers
    }
}
