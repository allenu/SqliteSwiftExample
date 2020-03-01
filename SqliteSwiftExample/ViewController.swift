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
    let itemsPerPage: Int = 25
    
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var searchField: NSSearchField!
    @IBOutlet weak var deleteLikeTextField: NSTextField!
    @IBOutlet weak var insertTextField: NSTextField!
    @IBOutlet weak var updateLikeTextField: NSTextField!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let directory = NSTemporaryDirectory()
        let subpath = UUID().uuidString
        let tempUrl = NSURL.fileURL(withPath: directory)
        let dbUrl = tempUrl.appendingPathComponent("\(subpath)-db.sqlite3")
        databaseManager = DatabaseManager(fileUrl: dbUrl)
        
        databaseManager.setupTables()
        DispatchQueue.global().async {
            self.databaseManager.generateRows(numRows: 1000)
        }
        
        

        tableView.dataSource = self
        tableView.delegate = self
        
        searchField.delegate = self
        
        // Need to listen to when user scrolls too far
        self.tableView.enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didObserveScroll(notification:)), name: NSView.boundsDidChangeNotification, object: self.tableView.enclosingScrollView?.contentView)

        NotificationCenter.default.addObserver(self, selector: #selector(dataDidChange(notification:)), name: DatabaseManager.dataDidChangeNotification, object: databaseManager)
        
        // Initial fill
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
            let tableOperations = self.databaseManager.setCacheWindow(newOffset: 0, newSize: self.itemsPerPage * 2)
            self.process(tableOperations: tableOperations)
        })
    }
    
    @objc func dataDidChange(notification: NSNotification) {
        let updatedIdentifiers: [String] = (notification.userInfo?["updatedIdentifiers"] as? [String]) ?? []
        let removedIdentifiers: [String] = (notification.userInfo?["removedIdentifiers"] as? [String]) ?? []

        // TODO: Get this from notification
        let insertedIdentifiers: [String] = []
        
        let tableOperations = databaseManager.updateCacheIfNeeded(updatedIdentifiers: updatedIdentifiers,
                                                                  insertedIdentifiers: insertedIdentifiers,
                                                                  removedIdentifiers: removedIdentifiers)
        
        process(tableOperations: tableOperations)
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
        print("visible rows: \(firstVisibleRow) to \(lastVisibleRow)")
        
        
        let tableOperations = databaseManager.setCacheWindow(newOffset: firstVisibleRow - 10, newSize: itemsPerPage * 2)
        process(tableOperations: tableOperations)

/*
        // If we scroll the bottom past 75% of our window, then move our window down
        let fetchTriggerDown: Int = databaseManager.effectiveWindowEndIndex() - itemsPerPage / 2
        let fetchTriggerUp: Int = databaseManager.effectiveWindowStartIndex()
        
        let newOffset: Int?
        
        if lastVisibleRow >= fetchTriggerDown || databaseManager.cachedIdentifiers.count == 0 {
            newOffset = max(0, lastVisibleRow - itemsPerPage)
        } else if firstVisibleRow < fetchTriggerUp {
            newOffset = firstVisibleRow - itemsPerPage
        } else {
            newOffset = nil
        }
        
        if let newOffset = newOffset {
            let tableOperations = databaseManager.setCacheWindow(newOffset: newOffset, newSize: itemsPerPage * 2)
            process(tableOperations: tableOperations)
        }
 */
    }
    
    @IBAction func didTapInsert(sender: NSButton) {
        let name = insertTextField.stringValue
        databaseManager.insertPerson(name: name)
    }

    @IBAction func didTapUpdateLike(sender: NSButton) {
        let name = updateLikeTextField.stringValue
        databaseManager.updateLike(name: name)
    }
    
    @IBAction func didTapDeleteLike(sender: NSButton) {
        let name = deleteLikeTextField.stringValue
        databaseManager.deleteLike(name: name)
    }
    
    func process(tableOperations: [TableOperation]) {
        if tableOperations.count > 0 {
            self.tableView.beginUpdates()
            tableOperations.forEach { operation in
                switch operation {
                case .none:
                    break
                    
                case .update(let position, let size):
                    var indexSet = IndexSet()
                    Array(position..<(position+size)).forEach { index in
                        indexSet.insert(index)
                    }
                    self.tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))

                case .insert(let position, let size):
                    var indexSet = IndexSet()
                    Array(position..<(position+size)).forEach { index in
                        indexSet.insert(index)
                    }
                    self.tableView.insertRows(at: indexSet, withAnimation: .slideDown)
                    
                case .remove(let position, let size):
                    var indexSet = IndexSet()
                    Array(position..<(position+size)).forEach { index in
                        indexSet.insert(index)
                    }
                    self.tableView.removeRows(at: indexSet, withAnimation: .slideUp)
                    
                case .reload:
                    self.tableView.reloadData()
                }
            }
            self.tableView.endUpdates()
        }
    }
    
}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return databaseManager.numItems()
    }
}

extension ViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        let aView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "MyCellView"), owner: nil) as! NSTableCellView
        
        if let person = databaseManager.cachedPerson(at: row) {
            aView.textField?.stringValue = "\(person.identifier) - \(person.name)"
        } else {
            aView.textField?.stringValue = "loading..."
        }
        
        return aView
    }
}

extension ViewController: NSSearchFieldDelegate {
    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        print("searchFieldDidStartSearching: \(sender.stringValue)")
        
        databaseManager.searchFilter = sender.stringValue
        databaseManager.resetCache()
        _ = databaseManager.setCacheWindow(newOffset: 0, newSize: itemsPerPage * 2)
        tableView.reloadData()
    }
    
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        print("searchFieldDidEndSearching")
        
        databaseManager.searchFilter = nil
        databaseManager.resetCache()
        _ = databaseManager.setCacheWindow(newOffset: 0, newSize: itemsPerPage * 2)
        tableView.reloadData()
    }
    
    func controlTextDidChange(_ obj: Notification) {
        print("search text did change: \(searchField.stringValue)")
        databaseManager.searchFilter = searchField.stringValue
        databaseManager.resetCache()
        _ =  databaseManager.setCacheWindow(newOffset: 0, newSize: itemsPerPage * 2)
        tableView.reloadData()
    }
}
