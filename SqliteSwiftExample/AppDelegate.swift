//
//  AppDelegate.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/9/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    var viewController: ViewController!
    var databaseManager: DatabaseManager!
    var databaseCacheWindow: DatabaseCacheWindow<DatabaseManager>!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Set up the data source
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
        
        NotificationCenter.default.addObserver(self, selector: #selector(dataDidChange(notification:)), name: DatabaseManager.dataDidChangeNotification, object: databaseManager)

        NotificationCenter.default.addObserver(self, selector: #selector(dataDidReload(notification:)), name: DatabaseManager.dataDidReloadNotification, object: databaseManager)

        if let window = NSApp.windows.first {
            if let contentViewController = window.contentViewController as? ViewController {
                contentViewController.dataSource = self
                contentViewController.delegate = self
                self.viewController = contentViewController
                Swift.print("Found main view controller")
            }
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    @objc func dataDidChange(notification: NSNotification) {
        let updatedIdentifiers: [String] = (notification.userInfo?["updatedIdentifiers"] as? [String]) ?? []
        let removedIdentifiers: [String] = (notification.userInfo?["removedIdentifiers"] as? [String]) ?? []
        let insertedIdentifiers: [String] = (notification.userInfo?["insertedIdentifiers"] as? [String]) ?? []
        
        let tableOperations = databaseCacheWindow.updateIfNeeded(updatedIdentifiers: updatedIdentifiers,
                                                                 insertedIdentifiers: insertedIdentifiers,
                                                                 removedIdentifiers: removedIdentifiers)
        
        let scrollToEndOnInsert = databaseCacheWindow.isViewingEnd
        let numItems = databaseCacheWindow.numItems
        viewController.tableView.process(tableOperations: tableOperations, scrollToEndOnInsert: scrollToEndOnInsert, numItems: numItems)
    }
    
    @objc func dataDidReload(notification: NSNotification) {
        databaseCacheWindow.clear()
        viewController.tableView.reloadData()
    }

}

extension AppDelegate: ViewControllerDataSource {
    func numItems(_ viewController: ViewController) -> Int {
        return databaseCacheWindow.numItems
    }
    
    func viewController(_ viewController: ViewController, itemAt index: Int) -> Person? {
        return databaseCacheWindow.item(at: index)
    }
    
    func viewController(_ viewController: ViewController, didUpdateViewWindowStarting offset: Int, size: Int) {
        let tableOperations = databaseCacheWindow.setCacheWindow(newOffset: offset, newSize: size)
        let scrollToEndOnInsert = databaseCacheWindow.isViewingEnd
        let numItems = databaseCacheWindow.numItems
        viewController.tableView.process(tableOperations: tableOperations,
                                         scrollToEndOnInsert: scrollToEndOnInsert,
                                         numItems: numItems)
    }
    
    func viewController(_ viewController: ViewController, didUpdateSearchFilter filter: String?) {
        databaseManager.searchFilter = filter
    }
}

extension AppDelegate: ViewControllerDelegate {
    func viewController(_ viewController: ViewController, didAddPerson name: String) {
        databaseManager.insertPerson(name: name)
    }
    
    func viewController(_ viewController: ViewController, didDeleteLike name: String) {
        databaseManager.deleteLike(name: name)
    }
    
    func viewController(_ viewController: ViewController, didUpdateLike name: String) {
        databaseManager.updateLike(name: name)
    }
}
