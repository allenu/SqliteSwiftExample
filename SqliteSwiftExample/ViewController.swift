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
    var databaseCacheWindow: DatabaseCacheWindow<DatabaseManager>!
    
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
        databaseCacheWindow = DatabaseCacheWindow(provider: databaseManager)
        
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

        NotificationCenter.default.addObserver(self, selector: #selector(dataDidReload(notification:)), name: DatabaseManager.dataDidReloadNotification, object: databaseManager)
    }
    
    @objc func dataDidChange(notification: NSNotification) {
        let updatedIdentifiers: [String] = (notification.userInfo?["updatedIdentifiers"] as? [String]) ?? []
        let removedIdentifiers: [String] = (notification.userInfo?["removedIdentifiers"] as? [String]) ?? []
        let insertedIdentifiers: [String] = (notification.userInfo?["insertedIdentifiers"] as? [String]) ?? []
        
        let tableOperations = databaseCacheWindow.updateIfNeeded(updatedIdentifiers: updatedIdentifiers,
                                                                 insertedIdentifiers: insertedIdentifiers,
                                                                 removedIdentifiers: removedIdentifiers)
        
        process(tableOperations: tableOperations)
    }
    
    @objc func dataDidReload(notification: NSNotification) {
        databaseCacheWindow.clear()
        tableView.reloadData()
    }
    
    @objc func didObserveScroll(notification: NSNotification) {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let tableOperations = databaseCacheWindow.setCacheWindow(newOffset: visibleRows.location - 5, newSize: visibleRows.length + 10)
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
            var shouldScrollToEnd = false
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
                    // Also scroll to end if needed
                    if databaseCacheWindow.isViewingEnd {
                        shouldScrollToEnd = true
                    } else {
                        self.tableView.enclosingScrollView?.flashScrollers()
                    }
                    
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
            if shouldScrollToEnd {
                self.tableView.scrollRowToVisible(self.databaseCacheWindow.numItems - 1)
            }
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
    }
    
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        databaseManager.searchFilter = nil
    }
    
    func controlTextDidChange(_ obj: Notification) {
        databaseManager.searchFilter = searchField.stringValue
    }
}
