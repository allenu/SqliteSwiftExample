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
    
    // Assume true until it's not
    var hasMoreRows = true
    
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
            let uuid = UUID().uuidString
            let names = [
                "John",
                "Paul",
                "George",
                "Ringo"
            ]
            let name = names[ (Int(arc4random()) % names.count) ]
            let weight = 100 + Int64(arc4random() % 50)
            let age = 10 + Int64(arc4random() % 40)
            
            let person = Person(identifier: uuid, name: "\(row) - \(name)", weight: weight, age: age)
            print("Creating person: \(person)")
            insert(person: person)
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
}
