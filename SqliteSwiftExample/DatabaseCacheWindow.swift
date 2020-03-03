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

    let dataSource: DatabaseCacheWindowDataSource
    var cachedIdentifiers: [String] = []
    var cacheWindowState = CacheWindowState(numKnownItems: 0, windowOffset: 0, windowSize: 0)
    
    // This is the desired offset the client requested. We won't actually
    // honor it with windowOffset since we try to maximize the cache size,
    // but if new items are appended, we use this to determine if we should
    // shift the cache forward.
    var desiredWindowOffset: Int = 0
    
    // How big caller wanted the cache to be. This grows based on the setCacheWindow() requests.
    var desiredWindowSize = 10

    // We cache a limited number of items in a lookup so that we don't have to ask the dataSource to fetch
    // them from disk/database. This requires that we catch all update events so that we keep
    // these items fresh.
    let maxItemsInLookup = 100
    // This is a list of items that are added to the lookup, sorted in order that they are added or looked up.
    // Most recently used items show up at the end. If an item is read from the cache, it is pulled to the end
    // of the list to indicate it was used. Items towards the front are liable to be flushed from the cache.
    var itemLookupIdentifiers: [String] = []
    var itemLookup: [String : Person] = [:]

    init(dataSource: DatabaseCacheWindowDataSource) {
        self.dataSource = dataSource
    }
    
    var numItems: Int {
        return cacheWindowState.numKnownItems
    }
    
    var isViewingEnd: Bool {
        // If our desired offset is greater than what we were able to set, it just
        // means we reached the end of the data. We always maintain full cache size if
        // possible, so this is the only scenario it can happen.
        return desiredWindowOffset > cacheWindowState.windowOffset
    }
    
    func updateCacheIfNeeded(updatedIdentifiers: [String],
                             insertedIdentifiers: [String],
                             removedIdentifiers: [String]) -> [TableOperation] {
        
        updatedIdentifiers.forEach { updatedIdentifier in
            // Remove updated item from cache to force new value to be fetched
            removeCachedItem(for: updatedIdentifier)
        }
        let updatedIndexes: [Int] = updatedIdentifiers.compactMap { identifier in
            return cachedIdentifiers.firstIndex(where: { $0 == identifier})
        }
        
        // Stop caching things that are deleted, to save on mem
        removedIdentifiers.forEach { removedIdentifier in
            removeCachedItem(for: removedIdentifier)
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
                if let person = item(for: identifier) {
                    if dataSource.databaseCacheWindow(self, searchFilterContains: person) {
                        
                        // If our desired window offset is actually deeper than the actual window offset,
                        // we are okay with trying to append. This scenario only happens if we are viewing
                        // the end of the cache and it can no longer grow.
                        let viewingEndOfCache = desiredWindowOffset > cacheWindowState.windowOffset

                        let notAlreadyInCache = !cachedIdentifiers.contains(identifier)
                        let belongsInRange: Bool
                        if let firstIdentifier = cachedIdentifiers.first,
                            let lastIdentifier = cachedIdentifiers.last {
                            
                            let greaterThanFirst = identifier > firstIdentifier
                            let lesserThanLast = identifier < lastIdentifier || cachedIdentifiers.count < desiredWindowSize-1
                            belongsInRange = greaterThanFirst && (lesserThanLast || viewingEndOfCache)
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
                            
                            // Do not insert if it would go at the end and would cause cache to grow too long.
                            // But do allow it if we are viewing the end of the list.
                            if insertIndex < desiredWindowSize-1 || viewingEndOfCache {
                                cachedIdentifiers.insert(identifier, at: insertIndex)
                                let effectiveInsertIndex = cacheWindowState.windowOffset + insertIndex
                                tmpTableOperations.append(.insert(at: effectiveInsertIndex, count: 1))

                                // If item gets too large, either shift windowOffset+drop first item (if at end of cache)
                                // or drop last item.
                                let windowOffsetShift: Int
                                if cachedIdentifiers.count == desiredWindowSize {
                                    if viewingEndOfCache {
                                        windowOffsetShift = 1
                                        cachedIdentifiers.removeFirst()
                                    } else {
                                        windowOffsetShift = 0
                                        cachedIdentifiers.removeLast()
                                    }
                                } else {
                                    windowOffsetShift = 0
                                }

                                cacheWindowState = CacheWindowState(numKnownItems: cacheWindowState.numKnownItems + 1,
                                                                    windowOffset: cacheWindowState.windowOffset + windowOffsetShift,
                                                                    windowSize: cachedIdentifiers.count)
                            }
                        }
                    }
                }
            }

            tableOperations = tmpTableOperations
        } else {
            tableOperations = []
        }
        
        return tableOperations
    }
    
    func item(for identifier: String) -> Person? {
        if let person = itemLookup[identifier] {
            // Item was looked up, so move it to the end of the list
            if let itemIndex = itemLookupIdentifiers.firstIndex(of: identifier) {
                itemLookupIdentifiers.remove(at: itemIndex)
                itemLookupIdentifiers.append(identifier)
            } else {
                assertionFailure("Item we looked up isn't in the itemLookupIdentifiers")
            }
            return person
        } else {
            let person = dataSource.databaseCacheWindow(self, itemFor: identifier)
            if let person = person {
                itemLookup[identifier] = person
                
                itemLookupIdentifiers.append(identifier)
                if itemLookupIdentifiers.count > maxItemsInLookup {
                    // Drop first item so we keep cache small
                    let firstCachedItemIdentifier = itemLookupIdentifiers.removeFirst()
                    itemLookup.removeValue(forKey: firstCachedItemIdentifier)
                }
            }
            return person
        }
    }
    
    func removeCachedItem(for identifier: String) {
        if let firstMatchingIndex = itemLookupIdentifiers.firstIndex(where: { $0 == identifier }) {
            itemLookupIdentifiers.remove(at: firstMatchingIndex)
        }
        itemLookup.removeValue(forKey: identifier)
    }
    
    func clear() {
        cacheWindowState = CacheWindowState(numKnownItems: 0, windowOffset: 0, windowSize: 0)
        desiredWindowOffset = 0
        cachedIdentifiers = []
        
        _ = setCacheWindow(newOffset: desiredWindowOffset, newSize: desiredWindowSize)
    }
    
    func setCacheWindow(newOffset: Int, newSize: Int) -> [TableOperation] {
        
        // Allow cache to grow to largest requested window size based on request
        desiredWindowSize = max(desiredWindowSize, newSize)
        desiredWindowOffset = newOffset
        
        let oldCacheWindowEnd = cacheWindowState.windowOffset + cacheWindowState.windowSize
        let newCacheWindowEnd = newOffset + newSize
        
        let hasNoCacheData = cacheWindowState.windowSize == 0
        
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
            
            let numCacheItemsOverLimit = cachedIdentifiers.count - desiredWindowSize
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
                let numCacheItemsOverLimit = cachedIdentifiers.count - desiredWindowSize
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
                // TODO: Uh oh -- NYI
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
        let cacheIndex = effectiveRow - cacheWindowState.windowOffset
        if cacheIndex < 0 {
            return nil
        } else if cacheIndex >= cachedIdentifiers.count {
            return nil
        } else {
            let identifier = cachedIdentifiers[cacheIndex]
            return item(for: identifier)
        }
    }
}
