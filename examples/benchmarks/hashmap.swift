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

func base64char(n: Int) -> String {
    if n == 0 { return "A" }
    else if n == 1 { return "B" }
    else if n == 2 { return "C" }
    else if n == 3 { return "D" }
    else if n == 4 { return "E" }
    else if n == 5 { return "F" }
    else if n == 6 { return "G" }
    else if n == 7 { return "H" }
    else if n == 8 { return "I" }
    else if n == 9 { return "J" }
    else if n == 10 { return "K" }
    else if n == 11 { return "L" }
    else if n == 12 { return "M" }
    else if n == 13 { return "N" }
    else if n == 14 { return "O" }
    else if n == 15 { return "P" }
    else if n == 16 { return "Q" }
    else if n == 17 { return "R" }
    else if n == 18 { return "S" }
    else if n == 19 { return "T" }
    else if n == 20 { return "U" }
    else if n == 21 { return "V" }
    else if n == 22 { return "W" }
    else if n == 23 { return "X" }
    else if n == 24 { return "Y" }
    else if n == 25 { return "Z" }
    else if n == 26 { return "a" }
    else if n == 27 { return "b" }
    else if n == 28 { return "c" }
    else if n == 29 { return "d" }
    else if n == 30 { return "e" }
    else if n == 31 { return "f" }
    else if n == 32 { return "g" }
    else if n == 33 { return "h" }
    else if n == 34 { return "i" }
    else if n == 35 { return "j" }
    else if n == 36 { return "k" }
    else if n == 37 { return "l" }
    else if n == 38 { return "m" }
    else if n == 39 { return "n" }
    else if n == 40 { return "o" }
    else if n == 41 { return "p" }
    else if n == 42 { return "q" }
    else if n == 43 { return "r" }
    else if n == 44 { return "s" }
    else if n == 45 { return "t" }
    else if n == 46 { return "u" }
    else if n == 47 { return "v" }
    else if n == 48 { return "w" }
    else if n == 49 { return "x" }
    else if n == 50 { return "y" }
    else if n == 51 { return "z" }
    else if n == 52 { return "0" }
    else if n == 53 { return "1" }
    else if n == 54 { return "2" }
    else if n == 55 { return "3" }
    else if n == 56 { return "4" }
    else if n == 57 { return "5" }
    else if n == 58 { return "6" }
    else if n == 59 { return "7" }
    else if n == 60 { return "8" }
    else if n == 61 { return "9" }
    else if n == 62 { return "-" }
    else if n == 63 { return "_" }

    return ""
}

func intToStr(n: Int) -> String {
    var s = ""
    var t = n
    var i = 0
    while i < 8 {
        s = base64char(n: t & 63) + s
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
    let t = makeTable()
    t.set(key: "hello", value: 1)
    t.set(key: "hi", value: 2)
    t.set(key: "hay", value: 3)
    t.set(key: "hai", value: 4)
    t.set(key: "sup", value: 5)
    t.set(key: "gday", value: 6)
    t.set(key: "ay", value: 7)
    t.set(key: "yo", value: 8)
    t.set(key: "yaho", value: 9)

    // show(t, "hello")   // 1
    // show(t, "yaho")    // 9
    // show(t, "missing") // 0

    // t.set("hi", 20)    // overwrite
    // show(t, "hi")      // 20

    // print(t.contains("hai"))   // 1 (true)
    // print(t.delete("hai"))     // 1 (true)
    // print(t.contains("hai"))   // 0 (false, now a tombstone)
    // print(t.delete("hai"))     // 0 (already gone)

    // show(t, "gday")    // 6 — still reachable past the tombstone

    var sng = SimpleRNG(seed: 42)

    let table = makeTable()
    let items_max = 1000000
    var i = 0
    while i < items_max {
        let k = intToStr(n: sng.next())
        table.set(key: k, value: i)
        i += 1
    }

    var sum = 0
    i = 0
    sng = SimpleRNG(seed: 42)
    while i < items_max {
        let maybe_i = table.get(key: intToStr(n: sng.next()))
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
