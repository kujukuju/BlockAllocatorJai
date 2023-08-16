// TODO maybe this can be updated to dynamically correspond to your cache size or something
// TODO or whatever size necessary to fit memory and active in cache idk
BlockAllocator :: struct (type: Type, block_count: int = 1024) {
    ITEM_OFFSET :: #run () -> int {
        struct_data := cast(*Type_Info_Struct) type_info(BlockInformation(type));
        for member: struct_data.members {
            if member.name == "item" {
                return member.offset_in_bytes;
            }
        }

        assert(false, "Could not find item offset.");
        return 0;
    }();
    memory: [..] [] BlockInformation(type);
    last_block_index: int;
    last_entry_index: int;
    count: int;
}

BlockInformation :: struct (type: Type) {
    active: bool;
    item: type;
}

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

    index := 0;
    while index < memory.count * N {
        defer index += 1;

        block_index: int = index / N;
        entry_index: int = index % N;

        // I forgot what this does, lets you assign?
        #if flags & .POINTER {
            if !memory[block_index][entry_index].active {
                continue;
            }

            `it_index := index;
            `it := *memory[block_index][entry_index].item;

            defer memory[block_index][entry_index].item = << it;
        
            #insert body;
        } else {
            if !memory[block_index][entry_index].active {
                continue;
            }

            `it_index := index;
            `it := memory[block_index][entry_index].item;
        
            #insert body;
        }
    }
}

claim :: (allocator: *BlockAllocator($T, $N)) -> *T {
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
    
    allocator.count += 1;

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

// #run () {
//     test_allocator: BlockAllocator(int);
//     int1 := claim(*test_allocator);
//     int1.* = 1;
//     int2 := claim(*test_allocator);
//     int2.* = 2;
//     int3 := claim(*test_allocator);
//     int3.* = 3;

//     for val: test_allocator {
//         print("Found1 %\n", val);
//     }

//     release(*test_allocator, int2);

//     for val: test_allocator {
//         print("Found2 %\n", val);
//     }
// }();

release :: (using allocator: *BlockAllocator($T, $N), entry: *T) {
    pointer := cast(*BlockInformation(T)) ((cast(*u8) entry) - ITEM_OFFSET);
    // TODO this whole thing should use an index system to point into the previously freed memory like a circle
    for block_index: 0..memory.count - 1 {
        block := memory[block_index];

        if pointer >= block.data && pointer < block.data + N {
            index_offset := cast(int) (pointer - block.data);

            if memory[block_index][index_offset].active {
                memory[block_index][index_offset].active = false;
                allocator.count -= 1;
            }
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

    allocator.count = 0;
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