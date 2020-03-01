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
    var databaseCacheWindow: DatabaseCacheWindow!
    let itemsPerPage: Int = 30
    
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
        databaseCacheWindow = DatabaseCacheWindow(dataSource: databaseManager)
        
        databaseManager.setupTables()
        DispatchQueue.global().async {
            self.databaseManager.generateRows(numRows: 150)
        }

        tableView.dataSource = self
        tableView.delegate = self
        
        searchField.delegate = self
        
        // Need to listen to when user scrolls too far
        self.tableView.enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didObserveScroll(notification:)), name: NSView.boundsDidChangeNotification, object: self.tableView.enclosingScrollView?.contentView)

        NotificationCenter.default.addObserver(self, selector: #selector(dataDidChange(notification:)), name: DatabaseManager.dataDidChangeNotification, object: databaseManager)
        
        // Initial fill
//        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
//            let tableOperations = self.databaseCacheWindow.setCacheWindow(newOffset: 0, newSize: self.itemsPerPage * 2)
//            self.process(tableOperations: tableOperations)
//        })
    }
    
    @objc func dataDidChange(notification: NSNotification) {
        let updatedIdentifiers: [String] = (notification.userInfo?["updatedIdentifiers"] as? [String]) ?? []
        let removedIdentifiers: [String] = (notification.userInfo?["removedIdentifiers"] as? [String]) ?? []
        let insertedIdentifiers: [String] = (notification.userInfo?["insertedIdentifiers"] as? [String]) ?? []
        
        let tableOperations = databaseCacheWindow.updateCacheIfNeeded(updatedIdentifiers: updatedIdentifiers,
                                                                  insertedIdentifiers: insertedIdentifiers,
                                                                  removedIdentifiers: removedIdentifiers)
        
        process(tableOperations: tableOperations)
    }
    
    @objc func didObserveScroll(notification: NSNotification) {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let tableOperations = databaseCacheWindow.setCacheWindow(newOffset: visibleRows.location - 10, newSize: itemsPerPage * 2)
        process(tableOperations: tableOperations)
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
                    print("process: updating rows at \(position) of size \(size)")
                    self.tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))

                case .insert(let position, let size):
                    var indexSet = IndexSet()
                    Array(position..<(position+size)).forEach { index in
                        indexSet.insert(index)
                    }
                    print("process: inserting rows at \(position) of size \(size)")
                    self.tableView.insertRows(at: indexSet, withAnimation: .slideDown)
                    self.tableView.enclosingScrollView?.flashScrollers()
                    
                case .remove(let position, let size):
                    var indexSet = IndexSet()
                    Array(position..<(position+size)).forEach { index in
                        indexSet.insert(index)
                    }
                    print("process: deleting rows at \(position) of size \(size)")
                    self.tableView.removeRows(at: indexSet, withAnimation: .slideUp)
                    
                case .reload:
                    print("process: reloading all rows")
                    self.tableView.reloadData()
                }
            }
            self.tableView.endUpdates()
        } else {
//            print("no changes to process")
        }
    }
    
}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return databaseCacheWindow.numItems
    }
}

extension ViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        let aView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "MyCellView"), owner: nil) as! NSTableCellView
        
        if let person = databaseCacheWindow.item(at: row) {
            aView.textField?.stringValue = "\(person.identifier) - \(person.name)"
        } else {
            aView.textField?.stringValue = "loading..."
        }
        
        return aView
    }
}

extension ViewController: NSSearchFieldDelegate {
    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        databaseManager.searchFilter = sender.stringValue
        databaseCacheWindow.resetCache()
        _ = databaseCacheWindow.setCacheWindow(newOffset: 0, newSize: itemsPerPage * 2)
        tableView.reloadData()
    }
    
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        databaseManager.searchFilter = nil
        databaseCacheWindow.resetCache()
        _ = databaseCacheWindow.setCacheWindow(newOffset: 0, newSize: itemsPerPage * 2)
        tableView.reloadData()
    }
    
    func controlTextDidChange(_ obj: Notification) {
        databaseManager.searchFilter = searchField.stringValue
        databaseCacheWindow.resetCache()
        _ =  databaseCacheWindow.setCacheWindow(newOffset: 0, newSize: itemsPerPage * 2)
        tableView.reloadData()
    }
}
