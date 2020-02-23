//
//  ViewController.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/9/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Cocoa
import SQLite

class ViewController: NSViewController {
    var databaseManager: DatabaseManager!
    let itemsPerPage: Int = 10
    
    @IBOutlet weak var tableView: NSTableView!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let directory = NSTemporaryDirectory()
        let subpath = UUID().uuidString
        let tempUrl = NSURL.fileURL(withPath: directory)
        let dbUrl = tempUrl.appendingPathComponent("\(subpath)-db.sqlite3")
        databaseManager = DatabaseManager(fileUrl: dbUrl)
        
        databaseManager.setupTables()
        databaseManager.generateRows(numRows: 5)
        _ = databaseManager.fetchPeople(numPeople: itemsPerPage * 2)

        tableView.dataSource = self

        // Need to listen to when user scrolls too far
        self.tableView.enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didObserveScroll(notification:)), name: NSView.boundsDidChangeNotification, object: self.tableView.enclosingScrollView?.contentView)
    }
    
    @objc func didObserveScroll(notification: NSNotification) {
        print("Scroll position: \(tableView.enclosingScrollView?.contentView.bounds.origin.y)")
        
        // Figure out content size of the window area by getting tableView height
        let tableViewHeight = tableView.bounds.height
        // Figure out the index of the last row showing by taking origin position of the scroll view and adding table height
        let firstRowY = (tableView.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
        let maxY = firstRowY + tableViewHeight
        let point = CGPoint(x: 0, y: maxY)
        let index = tableView.row(at: point)
        print("last row index there is \(index)")
        
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let lastVisibleRow = visibleRows.location + visibleRows.length
        print("lastVisibleRow is \(lastVisibleRow)")
        
        // If the row we are loading is beyond a certain point in the list, then we should go fetch more data
        let oldCount = databaseManager.numFetchedPeople()
        let fetchTrigger: Int = databaseManager.numFetchedPeople() - itemsPerPage / 2
        if lastVisibleRow >= fetchTrigger {
            // Can get more results, so do it ...
            if databaseManager.hasMoreRows {
                _ = self.databaseManager.fetchPeople(numPeople: itemsPerPage)
                
                var indexSet = IndexSet()
                Array(oldCount..<self.databaseManager.numFetchedPeople()).forEach { index in
                    print("inserting item at index \(index)")
                    indexSet.insert(index)
                }
                self.tableView.beginUpdates()
                self.tableView.insertRows(at: indexSet, withAnimation: .slideDown)
                self.tableView.endUpdates()
            } else {
                print("No more results to show")
            }

        }
    }
    
    @IBAction func addPerson(sender: NSButton) {
        databaseManager.generateRows(numRows: 1)
    }
}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return databaseManager.numFetchedPeople()
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let person = databaseManager.person(at: row) else { return nil }
        
//        let person = Person(identifier: "1234", name: "John \(row)", weight: Int64(row), age: 100 + Int64(row))
        
        if tableColumn!.identifier.rawValue == Person.namePropertyKey {
            return person.name
        } else if tableColumn!.identifier.rawValue == Person.identifierPropertyKey {
            return person.identifier
        } else if tableColumn!.identifier.rawValue == Person.weightPropertyKey {
            return person.weight
        } else if tableColumn!.identifier.rawValue == Person.agePropertyKey {
            return person.age
        } else {
            return nil
        }
    }
}
