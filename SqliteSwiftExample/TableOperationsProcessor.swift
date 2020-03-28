//
//  TableOperationsProcessor.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 3/28/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import AppKit

extension NSTableView {
    func process(tableOperations: [TableOperation], scrollToEndOnInsert: Bool, numItems: Int) {
        guard tableOperations.count > 0 else { return }
        
        var shouldScrollToEnd = false
        self.beginUpdates()
        tableOperations.forEach { operation in
            switch operation {
            case .none:
                break
                
            case .update(let position, let size):
                var indexSet = IndexSet()
                Array(position..<(position+size)).forEach { index in
                    indexSet.insert(index)
                }
                self.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(arrayLiteral: 0))

            case .insert(let position, let size):
                var indexSet = IndexSet()
                Array(position..<(position+size)).forEach { index in
                    indexSet.insert(index)
                }
                self.insertRows(at: indexSet, withAnimation: .slideDown)
                // Also scroll to end if needed
                if scrollToEndOnInsert {
                    shouldScrollToEnd = true
                } else {
                    self.enclosingScrollView?.flashScrollers()
                }
                
            case .remove(let position, let size):
                var indexSet = IndexSet()
                Array(position..<(position+size)).forEach { index in
                    indexSet.insert(index)
                }
                self.removeRows(at: indexSet, withAnimation: .slideUp)
                
            case .reload:
                self.reloadData()
            }
        }
        self.endUpdates()
        if shouldScrollToEnd {
            self.scrollRowToVisible(numItems - 1)
        }
    }
}
