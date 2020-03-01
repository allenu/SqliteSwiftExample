//
//  DatabaseCacheWindow.swift
//  SqliteSwiftExample
//
//  Created by Allen Ussher on 2/29/20.
//  Copyright © 2020 Ussher Press. All rights reserved.
//

import Foundation

struct CacheWindowState {
    let numKnownItems: Int
    let windowOffset: Int
    let windowSize: Int
}

struct GrowCacheWindowResult {
    let cacheWindowState: CacheWindowState
    let tableOperations: [TableOperation]
}

enum TableOperation {
    case none
    case reload
    case update(at: Int, count: Int)
    case insert(at: Int, count: Int)
    case remove(at: Int, count: Int)
}

// Attempt to grow a cache in reverse by delta items (negative delta value) or forwards (positive delta value).
// numItemsFetched indicates how many we were actually able to grow in that direction.
func growCacheWindow(from oldCacheWindowState: CacheWindowState, delta: Int, numItemsFetched: Int) -> GrowCacheWindowResult {
    if delta == 0 {
        assertionFailure("Must not call with delta == 0")
    }
    
    var tableOperations: [TableOperation] = []
    
    // Growing backwards
    var numItemsDeleted: Int = 0
    var numItemsInserted: Int = 0
    let newWindowOffset: Int
    if delta < 0 {
        let desiredItemsToFetch = -delta
        // We only expect to fetch either how many items are actual before our offset or the number requested,
        // whichever is smaller
        let numItemsExpected = min(desiredItemsToFetch, oldCacheWindowState.windowOffset)
        
        if numItemsFetched < numItemsExpected {
            // We fetched fewer than we expected, so this means we will have to delete some items
            numItemsDeleted = numItemsExpected - numItemsFetched
            
            let updatePosition = oldCacheWindowState.windowOffset - numItemsFetched
            let deletePosition = updatePosition - numItemsDeleted
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
            tableOperations.append(.remove(at: deletePosition, count: numItemsDeleted))
            
            // Move window down to delete position
            newWindowOffset = deletePosition
        } else if numItemsFetched > numItemsExpected {
            // We fetched more than we expected, so we need to insert new items
            numItemsInserted = numItemsFetched - numItemsExpected
            
            let updatePosition = oldCacheWindowState.windowOffset - numItemsExpected
            let numItemsUpdated = numItemsExpected
            let insertPosition = updatePosition // insert at same spot where update occurs since it goes before the item there
            if numItemsUpdated > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsUpdated))
            }
            tableOperations.append(.insert(at: insertPosition, count: numItemsInserted))

            newWindowOffset = insertPosition
        } else {
            // We fetched exactly the number we expected
            let updatePosition = oldCacheWindowState.windowOffset - numItemsFetched
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
            newWindowOffset = oldCacheWindowState.windowOffset - numItemsExpected
        }
    } else {
        let desiredItemsToFetch = delta

        // We only expect to fetch at most however many there are beyond the end of our window
        let numItemsBeyondWindow = oldCacheWindowState.numKnownItems - (oldCacheWindowState.windowOffset + oldCacheWindowState.windowSize)
        let numItemsExpected = min(desiredItemsToFetch, numItemsBeyondWindow)
        
        let updatePosition = oldCacheWindowState.windowOffset + oldCacheWindowState.windowSize
        if numItemsFetched < numItemsExpected {
            // We will need to delete some, but do it beyond where we just fetched
            numItemsDeleted = numItemsExpected - numItemsFetched
            
            let deletePosition = updatePosition + numItemsFetched
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
            tableOperations.append(.remove(at: deletePosition, count: numItemsDeleted))
        } else if numItemsFetched > numItemsExpected {
            // We need to insert some new ones at end of entire list
            numItemsInserted = numItemsFetched - numItemsExpected
            
            // Insert past the point where we expected
            let insertPosition = updatePosition + numItemsExpected
            tableOperations.append(.update(at: updatePosition, count: numItemsExpected))
            tableOperations.append(.insert(at: insertPosition, count: numItemsInserted))
        } else {
            // We fetched exactly what we expected.
            if numItemsFetched > 0 {
                tableOperations.append(.update(at: updatePosition, count: numItemsFetched))
            }
        }
        
        // Since we are growing at the end of our window, no need to update windowOffset
        newWindowOffset = oldCacheWindowState.windowOffset
    }
    
    let newWindowSize = oldCacheWindowState.windowSize + numItemsFetched
    let newNumKnownItems  = oldCacheWindowState.numKnownItems - numItemsDeleted + numItemsInserted
    let newCacheWindowState = CacheWindowState(numKnownItems: newNumKnownItems, windowOffset: newWindowOffset, windowSize: newWindowSize)
    
    return GrowCacheWindowResult(cacheWindowState: newCacheWindowState, tableOperations: tableOperations)
}

protocol DatabaseCacheWindowDataSource {
    func databaseCacheWindow(_ databaseCacheWindow: DatabaseCacheWindow, searchFilterContains item: Person) -> Bool
    func databaseCacheWindow(_ databaseCacheWindow: DatabaseCacheWindow, itemFor identifier: String) -> Person?
    func databaseCacheWindow(_ databaseCacheWindow: DatabaseCacheWindow, fetch limitCount: Int, itemsBefore identifier: String?) -> [String]
    func databaseCacheWindow(_ databaseCacheWindow: DatabaseCacheWindow, fetch limitCount: Int, itemsAfter identifier: String?) -> [String]
    func databaseCacheWindow(_ databaseCacheWindow: DatabaseCacheWindow, fetch limitCount: Int, itemsStartingAt offset: Int) -> [String]
}

class DatabaseCacheWindow {
    let maxCacheWindowSize = 80

    let dataSource: DatabaseCacheWindowDataSource
    var cachedIdentifiers: [String] = [] // TODO: Could also store full entries in memory?
    var cacheWindowState = CacheWindowState(numKnownItems: 0, windowOffset: 0, windowSize: 0)

    init(dataSource: DatabaseCacheWindowDataSource) {
        self.dataSource = dataSource
    }
    
    var numItems: Int {
        return cacheWindowState.numKnownItems
    }
    
    func updateCacheIfNeeded(updatedIdentifiers: [String],
                             insertedIdentifiers: [String],
                             removedIdentifiers: [String]) -> [TableOperation] {
        
        let updatedIndexes: [Int] = updatedIdentifiers.compactMap { identifier in
            return cachedIdentifiers.firstIndex(where: { $0 == identifier})
        }
        
        let unsortedDeletedIndexes: [Int] = removedIdentifiers.compactMap { identifier in
            return cachedIdentifiers.firstIndex(where: { $0 == identifier })
        }
        let deletedIndexes = unsortedDeletedIndexes.sorted()
        
        // TODO: Handle both update, insert, and delete somehow. We need to be very smart about
        // the order in which we do it ...
        
        let tableOperations: [TableOperation]
        if deletedIndexes.count > 0 {
            
            // Remove those items in reverse order from the cachedIdentifiers
            deletedIndexes.reversed().forEach { index in
                cachedIdentifiers.remove(at: index)
            }
            cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems - deletedIndexes.count,
                                                windowOffset: cacheWindowState.windowOffset,
                                                windowSize: cacheWindowState.windowSize - deletedIndexes.count)
            
            let deleteOperations: [TableOperation] = deletedIndexes.reversed().map { deletedIndex in
                return TableOperation.remove(at: cacheWindowState.windowOffset + deletedIndex, count: 1)
            }
            
            // Try to grow the cache some more
            let newSize = cacheWindowState.windowSize + deletedIndexes.count
            let insertOperations = setCacheWindow(newOffset: cacheWindowState.windowOffset, newSize: newSize)
            
            tableOperations = deleteOperations + insertOperations
        } else if updatedIndexes.count > 0 {
            tableOperations = updatedIndexes.map { updatedIndex in
                return TableOperation.update(at: cacheWindowState.windowOffset + updatedIndex, count: 1)
            }
        } else if insertedIdentifiers.count > 0 {
            
            var tmpTableOperations: [TableOperation] = []
            
            insertedIdentifiers.forEach { identifier in
                if let person = dataSource.databaseCacheWindow(self, itemFor: identifier) {
                    if dataSource.databaseCacheWindow(self, searchFilterContains: person) {
                        
                        let notAlreadyInCache = !cachedIdentifiers.contains(identifier)
                        let belongsInRange: Bool
                        if let firstIdentifier = cachedIdentifiers.first,
                            let lastIdentifier = cachedIdentifiers.last {
                            
                            let greaterThanFirst = identifier > firstIdentifier
                            let lesserThanLast = identifier < lastIdentifier || cachedIdentifiers.count < maxCacheWindowSize-1
                            belongsInRange = greaterThanFirst && lesserThanLast
                        } else {
                            belongsInRange = true
                        }
                        
                        if notAlreadyInCache && belongsInRange {
                            // Yes, this should be inserted. Find out where
                            let insertIndex: Int
                            if let insertBeforeIndex = cachedIdentifiers.firstIndex(where: { $0 > identifier }) {
                                insertIndex = insertBeforeIndex
                            } else {
                                insertIndex = cachedIdentifiers.count
                            }
                            
                            // Do not insert if it would go at the end and would cause cache to grow too long
                            if insertIndex < maxCacheWindowSize {
                                cachedIdentifiers.insert(identifier, at: insertIndex)
                                tmpTableOperations.append(.insert(at: insertIndex, count: 1))

                                // Drop item at end if this gets too large
                                if cachedIdentifiers.count == maxCacheWindowSize {
                                    cachedIdentifiers.removeLast()
                                }

                                cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems + 1,
                                                                    windowOffset: cacheWindowState.windowOffset,
                                                                    windowSize: cachedIdentifiers.count)
                            }
                        }
                    }
                }
            }

            tableOperations = tmpTableOperations
            
        } else {
            // TODO: if anything inserted ...
            // - see if it would appear in the range of our view of rows
            // - if so, insert it appropriately
            
            tableOperations = []
        }
        
        return tableOperations
    }
    
    
    func resetCache() {
        cacheWindowState = CacheWindowState(numKnownItems: 0, windowOffset: 0, windowSize: 0)
        cachedIdentifiers = []
    }
    
    func setCacheWindow(newOffset: Int, newSize: Int) -> [TableOperation] {
        
        let newSize = min(maxCacheWindowSize, newSize)
//        assert(newSize < maxCacheWindowSize)
        
        let oldCacheWindowEnd = cacheWindowState.windowOffset + cacheWindowState.windowSize
        let newCacheWindowEnd = newOffset + newSize
        
        let hasNoCacheData = cacheWindowState.windowSize == 0
        
//        print("newOffset: \(newOffset) of size \(newSize) -- old: \(cacheWindowState.windowOffset) size \(cacheWindowState.windowSize)")
        
        if newOffset < cacheWindowState.windowOffset && ((newCacheWindowEnd > cacheWindowState.windowOffset && newCacheWindowEnd < oldCacheWindowEnd) || cacheWindowState.windowSize == 0) {
            // Window moved backwards but overlaps old window
            
            // Fetch backwards
            // We only need to fetch enough rows to shift window up beyond where it already is
            let numItemsToFetch = cacheWindowState.windowOffset - newOffset
            
            let firstItemIdentifier = cachedIdentifiers.first
            let prependedIdentifiers = dataSource.databaseCacheWindow(self, fetch: numItemsToFetch, itemsBefore: firstItemIdentifier)
            let numItemsFetched = prependedIdentifiers.count
            
            let delta = newOffset - cacheWindowState.windowOffset
            let result = growCacheWindow(from: cacheWindowState, delta: delta, numItemsFetched: numItemsFetched)
            
            cachedIdentifiers.insert(contentsOf: prependedIdentifiers, at: 0)
            cacheWindowState = result.cacheWindowState
            
            let numCacheItemsOverLimit = cachedIdentifiers.count - maxCacheWindowSize
            if numCacheItemsOverLimit > 0 {
                // Remove last items if our cache gets too large
                _ = cachedIdentifiers.removeLast(numCacheItemsOverLimit)
                cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems, windowOffset: cacheWindowState.windowOffset, windowSize: cachedIdentifiers.count)
            }

            return result.tableOperations
            
        } else if newOffset >= cacheWindowState.windowOffset && (newOffset < oldCacheWindowEnd || cacheWindowState.windowSize == 0) || hasNoCacheData {
            // Window moved forwards but overlaps old window
            
            // Fetch forwards from oldCacheWindowEnd
            
            // We only need to fetch enough rows to shift window up beyond where it already is
            let numItemsToFetch = max(0, newCacheWindowEnd - oldCacheWindowEnd)
            if numItemsToFetch > 0 {
                // Try to fetch numItemsToFetch rows beyond the last item
                let lastItemIdentifier = cachedIdentifiers.last
                let appendedIdentifiers = dataSource.databaseCacheWindow(self, fetch: numItemsToFetch, itemsAfter: lastItemIdentifier)
                let numItemsFetched = appendedIdentifiers.count
                
                let delta = newCacheWindowEnd - oldCacheWindowEnd
                let result = growCacheWindow(from: cacheWindowState, delta: delta, numItemsFetched: numItemsFetched)
                
                cachedIdentifiers.append(contentsOf: appendedIdentifiers)
                cacheWindowState = result.cacheWindowState
                let numCacheItemsOverLimit = cachedIdentifiers.count - maxCacheWindowSize
                if numCacheItemsOverLimit > 0 {
                    // Remove first items if our cache gets too large
                    _ = cachedIdentifiers.removeFirst(numCacheItemsOverLimit)
                    cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems, windowOffset: cacheWindowState.windowOffset + numCacheItemsOverLimit, windowSize: cachedIdentifiers.count)
                }
                
                return result.tableOperations
            } else {
                // We had nothing to fetch, so do nothing
                return []
            }
        } else if cacheWindowState.windowOffset == newOffset && cacheWindowState.windowSize == newSize {
            // Same content as before. Do nothing.
            return []
        } else {
            // No overlap, so we are arbitrarily positioning it somewhere
            
            // Ensure we don't go below zero for these cases
            let adjustedNewOffset = max(0, newOffset)
            
            let newIdentifiers = dataSource.databaseCacheWindow(self, fetch: newSize, itemsStartingAt: adjustedNewOffset)
            let numItemsFetched = newIdentifiers.count
            
            cachedIdentifiers = newIdentifiers
            
            if numItemsFetched == 0 {
                // Uh oh -- NYI
                return []
            } else {
                let numItemsExpected = min(cacheWindowState.numKnownItems - adjustedNewOffset, newSize)
                let numKnownItems: Int
                if numItemsFetched < numItemsExpected {
                    // Got fewer than expected, so do delete
                    
//                    print("Got fewer than expected, so do delete")
                    
                    numKnownItems = adjustedNewOffset + numItemsFetched
                    let numItemsDeleted = numItemsExpected - numItemsFetched
                    
                    let operations: [TableOperation] = [
                        .remove(at: adjustedNewOffset + numItemsFetched, count: numItemsDeleted)
                    ]
                    
                    cacheWindowState = CacheWindowState(numKnownItems: numKnownItems, windowOffset: adjustedNewOffset, windowSize: numItemsFetched)
                    return operations
                } else if numItemsFetched > numItemsExpected {
                    // Got more than expected
//                    print("Got more than expected")
                    
                    numKnownItems = adjustedNewOffset + numItemsFetched
                    let numItemsInserted = numItemsFetched - numItemsExpected
                    
                    let operations: [TableOperation] = [
                        .insert(at: adjustedNewOffset + numItemsExpected, count: numItemsInserted)
                    ]
                    
                    cacheWindowState = CacheWindowState(numKnownItems: numKnownItems, windowOffset: adjustedNewOffset, windowSize: numItemsFetched)
                    return operations

                } else {
                    // Got everything we expected
//                    print("Got everything we expected: adjustedNewOffset: \(adjustedNewOffset) numItemsFetched \(numItemsFetched)")
                    
                    assert(adjustedNewOffset >= 0)
                    
                    if numItemsFetched > 0 {
                        let operations: [TableOperation] = [
                            .update(at: adjustedNewOffset, count: numItemsFetched)
                        ]
                        
                        cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems, windowOffset: adjustedNewOffset, windowSize: numItemsFetched)
                        return operations
                    } else {
                        // Nothing fetched
                        return []
                    }
                }
            }
        }
    }
    
    func item(at effectiveRow: Int) -> Person? {
        // TODO: see if in cache of Person items
        
        let cacheIndex = effectiveRow - cacheWindowState.windowOffset
        if cacheIndex < 0 {
            return nil
        } else if cacheIndex >= cachedIdentifiers.count {
            return nil
        } else {
            let identifier = cachedIdentifiers[cacheIndex]
            return dataSource.databaseCacheWindow(self, itemFor: identifier)
        }
    }
}
