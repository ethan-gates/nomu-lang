// An open-addressing hash table (String -> Int), after the Crafting Interpreters `table.c`:
// linear probing, FNV-1a hashing (String.hash), tombstone deletion, and grow-and-rehash at a
// 0.75 load factor. Written in Nomu on top of `Array`, using the `String.hash` / `String.eq`
// builtins. Value type is a concrete `Int` for now (a generic dictionary comes later).
//
// A slot's `state` is 0 empty, 1 live, 2 tombstone. Only live slots hold a real key/value; the
// state field (not a key sentinel) marks occupancy, so an empty-string key is a normal key.
// Elements are read field-wise (`entries[i].state`, `.key`, `.value`) and written whole
// (`entries[i] = Entry(...)`), which is what the array element model supports today.


class SimpleRNG {
    var seed: Int
    init(seed: Int) {
        self.seed = seed
    }
    // Smaller parameters to prevent native Int overflow crashes

    // Generates the next pseudo-random Int
    func next() -> Int {
        // Uses only standard multiplication, addition, and remainder operators
        let t = 1103515245 * self.seed + 12345
        self.seed = t % 2147483647
        return self.seed
    }

    // Returns a random Int within a bounded range
    func nextInBound(min: Int, max: Int) -> Int {
        let currentRandom = self.next()
        let rangeSize = max - min + 1
        let scaledValue = currentRandom % rangeSize
        return scaledValue + min
    }
}

struct Entry {
    var state: Int
    var key: String
    var value: Int
}

func int_to_str(n: Int, chars: Int = 6) -> String {
    var s = ""
    var t = n
    var i = 0
    while i < chars {
        let b64_dec = t & 63
        var b64_ascii = 0
        if b64_dec < 26 {
            b64_ascii = b64_dec + 65
        } else if b64_dec < 52 {
            b64_ascii = b64_dec + 71
        } else if b64_dec < 62 {
            b64_ascii = b64_dec - 4
        } else if b64_dec == 62 {
            b64_ascii = 45
        } else {
            b64_ascii = 95
        }
        if let scalar = UnicodeScalar(b64_ascii) {
            s.append(Character(scalar))
        }
        t = t >> 6
        i += 1
    }

    return s
}

extension String {
    /// Calculates the 64-bit FNV-1a hash of the string.
    func fnv1a_64() -> Int {
        let fnvOffsetBasis: UInt = 14695981039346656037
        let fnvPrime: UInt = 1099511628211

        // Handle standard UTF-8 byte sequence
        let r = self.utf8.reduce(fnvOffsetBasis) { hash, byte in
            // XOR the lower 8 bits with the byte, then multiply with overflow handling
            (hash ^ UInt(byte)) &* fnvPrime
        }

        return Int(r % (UInt.max / 2))
    }
}

class HashTable {
    var entries: Array<Entry>
    var count: Int          // live + tombstones (drives the load factor)
    var capacity: Int

    init() {
        self.entries = []
        self.count = 0
        self.capacity = 0
    }

    // The slot a key lives in, or the slot it should be inserted into: the first tombstone seen
    // while probing (reused), else the terminating empty slot. A returned slot with state 1 is a
    // match; any other state means the key is absent.
    func findSlot(key: String) -> Int {
        let l = self.capacity - 1
        var idx = key.fnv1a_64() & l
        if idx < 0 {
            idx = idx + self.capacity
        }
        var firstTomb = -1
        var probes = 0
        while probes < self.capacity {
            let st = self.entries[idx].state
            if st == 0 {
                if firstTomb < 0 {
                    return idx
                }
                return firstTomb
            }
            if st == 2 {
                if firstTomb < 0 {
                    firstTomb = idx
                }
            } else {
                if self.entries[idx].key == key {
                    return idx
                }
            }
            idx = idx + 1
            if idx == self.capacity {
                idx = 0
            }
            probes = probes + 1
        }
        // The table is full of live + tombstone slots (the load factor keeps this from happening
        // in practice). Fall back to a tombstone if one was seen.
        if firstTomb < 0 {
            return idx
        }
        return firstTomb
    }

    // Grow (or first-allocate) to `newCap` and rehash the live entries. Tombstones and empties are
    // dropped; `count` becomes the live count.
    func resize(newCap: Int) {
        let old = self.entries
        let oldCap = self.capacity
        var fresh: Array<Entry> = []
        var j = 0
        while j < newCap {
            fresh.append(Entry(state: 0, key: "", value: 0))
            j = j + 1
        }
        self.entries = fresh
        self.capacity = newCap
        self.count = 0
        var i = 0
        while i < oldCap {
            if old[i].state == 1 {
                self.insertLive(key: old[i].key, value: old[i].value)
            }
            i = i + 1
        }
    }

    // Insert a known-absent key into a table with no matching key (used during rehash). Always
    // lands on an empty slot, so it always adds to the live count.
    func insertLive(key: String, value: Int) {
        let idx = self.findSlot(key: key)
        self.entries[idx] = Entry(state: 1, key: key, value: value)
        self.count = self.count + 1
    }

    func set(key: String, value: Int) {
        if self.count * 4 + 4 > self.capacity * 3 {   // (count + 1) / capacity > 0.75
            self.resize(newCap: self.capacity * 2)
        }
        let idx = self.findSlot(key: key)
        let st = self.entries[idx].state
        self.entries[idx] = Entry(state: 1, key: key, value: value)
        if st == 0 {
            self.count = self.count + 1   // filled a fresh bucket; tombstone reuse / overwrite do not
        }
    }

    func get(key: String) -> Int? {
        let idx = self.findSlot(key: key)
        if self.entries[idx].state == 1 {
            return self.entries[idx].value
        }
        return .none
    }

    func contains(key: String) -> Bool {
        let idx = self.findSlot(key: key)
        return self.entries[idx].state == 1
    }

    // Replace a live slot with a tombstone. `count` is unchanged: the tombstone still occupies the
    // probe sequence (that is what tombstones are for).
    func delete(key: String) -> Bool {
        let idx = self.findSlot(key: key)
        if self.entries[idx].state == 1 {
            self.entries[idx] = Entry(state: 2, key: "", value: 0)
            return true
        }
        return false
    }
}

func makeTable() -> HashTable {
    let t = HashTable()
    t.resize(newCap: 8)
    return t
}

func show(t: HashTable, key: String) {
    switch t.get(key: key) {
    case .some(let v): print(v)
    case .none:        print(0)
    }
}

func expected_sum(n: Int) -> Int {
    let half = n / 2
    return n * half - half
}

func main() {
    var sng = SimpleRNG(seed: 42)
    let table = makeTable()
    let items_max = 1000000

    var i = 0
    while i < items_max {
        let k = int_to_str(n: sng.next())
        table.set(key: k, value: i)
        i += 1
    }

    var sum = 0
    i = 0
    sng = SimpleRNG(seed: 42)
    while i < items_max {
        let maybe_i = table.get(key: int_to_str(n: sng.next()))
        switch maybe_i {
            case .some(let actual): sum += actual
            case .none: break
        }
        i += 1
    }

    print("table stats: count=\(table.count) cap=\(table.capacity)")
    let ex = expected_sum(n: items_max)
    if ex != sum {
        print("ERROR: sum doesn't match")
        print(sum)
        print(ex)
    }
}

main()
