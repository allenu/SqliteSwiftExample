//
//  ViewController.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/9/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Cocoa
import SQLite

protocol ViewControllerDelegate: class {
    func viewController(_ viewController: ViewController, didAddPerson name: String)
    func viewController(_ viewController: ViewController, didUpdateLike name: String)
    func viewController(_ viewController: ViewController, didDeleteLike name: String)
    
}

protocol ViewControllerDataSource: class {
    func numItems(_ viewController: ViewController) -> Int
    func viewController(_ viewController: ViewController, itemAt index: Int) -> Person?
    func viewController(_ viewController: ViewController, didUpdateViewWindowStarting offset: Int, size: Int)
    func viewController(_ viewController: ViewController, didUpdateSearchFilter filter: String?)
}

class ViewController: NSViewController{
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var searchField: NSSearchField!
    @IBOutlet weak var deleteLikeTextField: NSTextField!
    @IBOutlet weak var insertTextField: NSTextField!
    @IBOutlet weak var updateLikeTextField: NSTextField!
    
    weak var dataSource: ViewControllerDataSource?
    weak var delegate: ViewControllerDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.dataSource = self
        tableView.delegate = self
        
        searchField.delegate = self
        
        // Need to listen to when user scrolls too far
        self.tableView.enclosingScrollView?.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didObserveScroll(notification:)), name: NSView.boundsDidChangeNotification, object: self.tableView.enclosingScrollView?.contentView)
    }
    
    @objc func didObserveScroll(notification: NSNotification) {
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        let offset = visibleRows.location - 5
        let size = visibleRows.length + 10
        
        dataSource?.viewController(self, didUpdateViewWindowStarting: offset, size: size)
    }
    
    @IBAction func didTapInsert(sender: NSButton) {
        let name = insertTextField.stringValue
        delegate?.viewController(self, didAddPerson: name)
    }

    @IBAction func didTapUpdateLike(sender: NSButton) {
        let name = updateLikeTextField.stringValue
        delegate?.viewController(self, didUpdateLike: name)
    }
    
    @IBAction func didTapDeleteLike(sender: NSButton) {
        let name = deleteLikeTextField.stringValue
        delegate?.viewController(self, didDeleteLike: name)
    }
}

extension ViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        return dataSource?.numItems(self) ?? 0
    }
}

extension ViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        
        let aView = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(rawValue: "MyCellView"), owner: nil) as! NSTableCellView
        
        if let person = dataSource?.viewController(self, itemAt: row) {
            aView.textField?.stringValue = "\(person.identifier) - \(person.name)"
        } else {
            aView.textField?.stringValue = "loading..."
        }
        
        return aView
    }
}

extension ViewController: NSSearchFieldDelegate {
    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        dataSource?.viewController(self, didUpdateSearchFilter: sender.stringValue)
    }
    
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        dataSource?.viewController(self, didUpdateSearchFilter: nil)
    }
    
    func controlTextDidChange(_ obj: Notification) {
        dataSource?.viewController(self, didUpdateSearchFilter: searchField.stringValue)
    }
}
