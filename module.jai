// TODO maybe this can be updated to dynamically correspond to your cache size or something
// TODO or whatever size necessary to fit memory and active in cache idk
BlockAllocator :: struct (type: Type, count: int = 1024) {
    memory: [..] [] BlockInformation(type);
    last_block_index: int;
    last_entry_index: int;
}

BlockInformation :: struct (type: Type) {
    active: bool;
    item: type;
}

// TODO do this dynamically
ITEM_OFFSET :: size_of(bool);

operator [] :: (using allocator: BlockAllocator($T, $N), index: int) -> T {
    #if DEBUG {
        assert(index >= 0 && index < memory.count * N);
    }

    block_index: int = index / N;
    entry_index: int = index % N;

    assert(memory[block_index][entry_index].active, "Cannot access unclaimed memory.");
    if !memory[block_index][entry_index].active {
        return .{};
    }

    return memory[block_index][entry_index].item;
}

operator [] :: (using allocator: *BlockAllocator($T, $N), index: int) -> *T {
    #if DEBUG {
        assert(index >= 0 && index < memory.count * N);
    }

    block_index: int = index / N;
    entry_index: int = index % N;

    if !memory[block_index][entry_index].active {
        return null;
    }

    return *memory[block_index][entry_index].item;
}

// TODO should use fancy next pointer things to hop around to only active memory, I think?
for_expansion :: (using allocator: *BlockAllocator($T, $N), body: Code, flags: For_Flags) #expand {
    #assert(!(flags & .REVERSE)); // We don't handle the reverse flag.

    `it_index := 0;
    while it_index < memory.count * N {
        block_index: int = it_index / N;
        entry_index: int = it_index % N;

        // I forgot what this does, lets you assign?
        #if flags & .POINTER {
            if !memory[block_index][entry_index].active {
                it_index += 1;
                continue;
            }

            `it := *memory[block_index][entry_index].item;
        
            #insert body;

            memory[block_index][entry_index].active = ifx it == null then false else true;
            memory[block_index][entry_index].item = << it;
        } else {
            if !memory[block_index][entry_index].active {
                it_index += 1;
                continue;
            }

            it := memory[block_index][entry_index].item;
        
            #insert body;
        }
        
        it_index += 1;
    }
}

claim :: (allocator: *BlockAllocator($T)) -> *T {
    entry: T;
    return claim(allocator, entry);
}

claim :: (using allocator: *BlockAllocator($T, $N), entry: T) -> *T {
    if memory.count > 0 {
        last_block_index = (last_block_index % memory.count);
    }

    if last_block_index >= memory.count {
        memory_entry := NewArray(N, BlockInformation(T));
        array_add(*memory, memory_entry);
    }

    assert(last_block_index < memory.count, "Attempting to allocate into memory that doesn't exist.");

    start_block_index := last_block_index;
    start_entry_index := last_entry_index;

    if !memory[last_block_index][last_entry_index].active {
        memory[last_block_index][last_entry_index].item = entry;
        memory[last_block_index][last_entry_index].active = true;

        pointer: *T = *memory[last_block_index][last_entry_index].item;
        last_block_index, last_entry_index = increment_index(allocator, last_block_index, last_entry_index);

        return pointer;
    }

    last_block_index, last_entry_index = increment_index(allocator, last_block_index, last_entry_index);

    while last_block_index != start_block_index && last_entry_index != start_entry_index {
        if !memory[last_block_index][last_entry_index].active {
            memory[last_block_index][last_entry_index].item = entry;
            memory[last_block_index][last_entry_index].active = true;

            pointer: *T = *memory[last_block_index][last_entry_index].item;
            last_block_index, last_entry_index = increment_index(allocator, last_block_index, last_entry_index);

            return pointer;
        }

        last_block_index, last_entry_index = increment_index(allocator, last_block_index, last_entry_index);
    }

    // no available memory exists, so add more
    memory_entry := NewArray(N, BlockInformation(T));
    array_add(*memory, memory_entry);

    last_block_index = memory.count - 1;
    last_entry_index = 0;

    memory[last_block_index][last_entry_index].item = entry;
    memory[last_block_index][last_entry_index].active = true;

    pointer: *T = *memory[last_block_index][last_entry_index].item;
    last_block_index, last_entry_index = increment_index(allocator, last_block_index, last_entry_index);

    return pointer;
}

release :: (using allocator: *BlockAllocator($T, $N), entry: *T) {
    pointer := cast(*BlockInformation(T)) ((cast(*u8) entry) - ITEM_OFFSET);
    // TODO this whole thing should use an index system to point into the previously freed memory like a circle
    for block_index: 0..memory.count - 1 {
        block := memory[block_index];

        if pointer >= block.data && pointer < block.data + N {
            index_offset := pointer - block.data;

            memory[block_index][index_offset].active = false;
            return;
        }
    }

    assert(false, "Could not find entry to free.");
}

clear :: (using allocator: *BlockAllocator($T, $N)) {
    entry: [N] BlockInformation(T);

    for block_index: 0..memory.count - 1 {
        memcpy(memory[block_index].data, entry.data, size_of(type_of(entry)));
    }
}

validate_empty :: (using allocator: BlockAllocator($T, $N)) {
    for block_index: 0..memory.count - 1 {
        for i: 0..N - 1 {
            assert(!memory[block_index][i].active, "Could not validate block allocator as empty.");
        }
    }
}

#scope_file

DEBUG :: true;

increment_index :: inline (allocator: *BlockAllocator($T, $N), block_index: int, entry_index: int) -> block_index: int, entry_index: int {
    if entry_index == N - 1 {
        next_block_index := (block_index + 1) % N;

        return next_block_index, 0;
    }

    return block_index, entry_index + 1;
}

#import "Basic";