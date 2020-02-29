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
    let itemsPerPage: Int = 20
    
    var useNewCacheSystem = true
    
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var searchField: NSSearchField!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let directory = NSTemporaryDirectory()
        let subpath = UUID().uuidString
        let tempUrl = NSURL.fileURL(withPath: directory)
        let dbUrl = tempUrl.appendingPathComponent("\(subpath)-db.sqlite3")
        databaseManager = DatabaseManager(fileUrl: dbUrl)
        
        databaseManager.setupTables()
        DispatchQueue.global().async {
            self.databaseManager.generateRows(numRows: 10000)
        }
        _ = databaseManager.fetchPeople(numPeople: itemsPerPage * 2)
        databaseManager.prefetchCache(cachedWindowSize: itemsPerPage * 2)

        tableView.dataSource = self
        tableView.delegate = self
        
        searchField.delegate = self
        
        // Need to listen to when user scrolls too far
        self.tableView.enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didObserveScroll(notification:)), name: NSView.boundsDidChangeNotification, object: self.tableView.enclosingScrollView?.contentView)
    }
    
    @objc func didObserveScroll(notification: NSNotification) {
//        print("Scroll position: \(tableView.enclosingScrollView?.contentView.bounds.origin.y)")
        
        // Figure out content size of the window area by getting tableView height
        let tableViewHeight = tableView.bounds.height
        // Figure out the index of the last row showing by taking origin position of the scroll view and adding table height
        let firstRowY = (tableView.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
        let maxY = firstRowY + tableViewHeight
        let point = CGPoint(x: 0, y: maxY)
        let index = tableView.row(at: point)
//        print("last row index there is \(index)")
        
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let lastVisibleRow = visibleRows.location + visibleRows.length
        let firstVisibleRow = visibleRows.location
//        print("lastVisibleRow is \(lastVisibleRow) - first is \(firstVisibleRow)")
        
        if useNewCacheSystem {
            // If we scroll the bottom past 75% of our window, then move our window down
            let fetchTriggerDown: Int = databaseManager.effectiveWindowEndIndex() - itemsPerPage / 2
            let fetchTriggerUp: Int = databaseManager.effectiveWindowStartIndex()
            if lastVisibleRow >= fetchTriggerDown || databaseManager.cachedIdentifiers.count == 0 {
                let shiftResult = databaseManager.shiftCacheWindow(down: itemsPerPage / 2)
                switch shiftResult.1 {
                case .none:
                    // Do nothing. We already know about those entries that we're shifting down to show.
                    
                    // HACK: To get around the fact that NSTableView loads data for ALL rows even ones
                    // not visible on-screen, just reload the data for the visible rows.
                    var indexSet = IndexSet()
                    Array(databaseManager.effectiveWindowStartIndex()..<databaseManager.effectiveWindowEndIndex()).forEach { index in
                        indexSet.insert(index)
                    }
                    self.tableView.beginUpdates()
                    self.tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))
                    self.tableView.endUpdates()
                    
                case .update(let index, let count):
                    var indexSet = IndexSet()
                    Array(index..<(index + count)).forEach { index in
                        indexSet.insert(index)
                    }
                    if indexSet.count > 0 {
//                        print("updating rows from \(index) to \(index + count)")
                        self.tableView.beginUpdates()
                        self.tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))
                        self.tableView.endUpdates()
                    }
                    
                case .insert(let index, let count):
                    var indexSet = IndexSet()
                    Array(index..<(index + count)).forEach { index in
                        indexSet.insert(index)
                    }
                    if indexSet.count > 0 {
                        self.tableView.beginUpdates()
                        self.tableView.insertRows(at: indexSet, withAnimation: .slideDown)
                        self.tableView.endUpdates()
                    }
                    
                case .remove:
                    assertionFailure("NYI - we detected fewer items than expected at head")
                }
            } else if firstVisibleRow < fetchTriggerUp {
                let shiftResult = databaseManager.shiftCacheWindow(up: itemsPerPage)
                switch shiftResult.1 {
                case .none:
                    // Do nothing. We already know about those entries that we're shifting up to show.
                    // HACK: To get around the fact that NSTableView loads data for ALL rows even ones
                    // not visible on-screen, just reload the data for the visible rows.
                    var indexSet = IndexSet()
                    Array(databaseManager.effectiveWindowStartIndex()..<databaseManager.effectiveWindowEndIndex()).forEach { index in
                        indexSet.insert(index)
                    }
                    if indexSet.count > 0 {
                        self.tableView.beginUpdates()
                        self.tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))
                        self.tableView.endUpdates()
                    }
                    
                case .update(let index, let count):
                    var indexSet = IndexSet()
                    Array(index..<(index + count)).forEach { index in
                        indexSet.insert(index)
                    }
                    if indexSet.count > 0 {
//                        print("updating rows from \(index) to \(index + count)")
                        self.tableView.beginUpdates()
                        self.tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))
                        self.tableView.endUpdates()
                    }
                    
                case .insert(let index, let count):
                    assertionFailure("NYI - we detected inserted items in tail")

                case .remove:
                    assertionFailure("NYI - we detected fewer items in tail")
                }
                
            }
        } else {
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
    }
    
    @IBAction func addPerson(sender: NSButton) {
        databaseManager.generateRows(numRows: 1)
    }
}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        if useNewCacheSystem {
            return databaseManager.numFuzzyItems()
        } else {
            return databaseManager.numFetchedPeople()
        }
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let fetchedPerson: Person?
        
        if useNewCacheSystem {
            fetchedPerson = databaseManager.cachedPerson(at: row)
        } else {
            fetchedPerson = databaseManager.person(at: row)
        }
        
        guard let person = fetchedPerson else { return "NOT-CACHED" }
        
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

extension ViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        let aView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "MyCellView"), owner: nil) as! NSTableCellView
        
        
//        let view = NSTextField()
        
        if let person = databaseManager.cachedPerson(at: row) {
            aView.textField?.stringValue = "\(person.identifier) - \(person.name)"
//            view.stringValue = "\(person.identifier) - \(person.name)"
        } else {
            aView.textField?.stringValue = "loading..."
//            view.stringValue = "NOT-CACHED"
        }
        
        return aView
    }
}

extension ViewController: NSSearchFieldDelegate {
    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        print("searchFieldDidStartSearching: \(sender.stringValue)")
        
        databaseManager.searchFilter = sender.stringValue
        databaseManager.resetCache()
        databaseManager.prefetchCache(cachedWindowSize: itemsPerPage * 2)
        tableView.reloadData()
    }
    
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        print("searchFieldDidEndSearching")
        
        databaseManager.searchFilter = nil
        databaseManager.resetCache()
        databaseManager.prefetchCache(cachedWindowSize: itemsPerPage * 2)
        tableView.reloadData()
    }
    
    func controlTextDidChange(_ obj: Notification) {
        print("search text did change: \(searchField.stringValue)")
        databaseManager.searchFilter = searchField.stringValue
        databaseManager.resetCache()
        databaseManager.prefetchCache(cachedWindowSize: itemsPerPage * 2)
        tableView.reloadData()
    }
}
