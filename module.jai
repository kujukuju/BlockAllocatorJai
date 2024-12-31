
BlockAllocator :: struct (T: Type, N: int = 64) {
    ITEM_OFFSET :: #run () -> int {
        struct_data := cast(*Type_Info_Struct) type_info(BlockEntry(T));
        for member: struct_data.members {
            if member.name == "item" {
                return member.offset_in_bytes;
            }
        }

        assert(false, "Could not find item offset.");
        return 0;
    }();

    allocator: Allocator;

    memory: [..] Block(T);
    count: int;
}

Block :: struct (T: Type) {
    entries: [] BlockEntry(T);
    count: int;
}

BlockEntry :: struct (T: Type) {
    active: bool;
    item: T;
}

// TODO should use fancy next pointer things to hop around to only active memory, I think?
for_expansion :: (allocator: *BlockAllocator($T, $N), body: Code, flags: For_Flags) #expand {
    #assert(!(flags & .REVERSE));

    // we can't use an actual for loop because remove could delete a chunk potentially
    index := 0;
    while index < allocator.memory.count * N {
        defer index += 1;
        
        block_index: int = index / N;
        entry_index: int = index % N;

        if !allocator.memory[block_index].entries[entry_index].active {
            continue;
        }

        #if flags & .POINTER {
            `it := *allocator.memory[block_index].entries[entry_index].item;
            `it_index := index;
        } else {
            `it := allocator.memory[block_index].entries[entry_index].item;
            `it_index := index;
        }

        #insert (remove={release(allocator, index);}) body;
    }
}

operator [] :: (allocator: BlockAllocator($T, $N), index: int) -> T {
    block_index: int = index / N;
    entry_index: int = index % N;

    assert(allocator.memory[block_index].entries[entry_index].active, "Cannot access unclaimed memory.");
    if !allocator.memory[block_index].entries[entry_index].active {
        return .{};
    }

    return allocator.memory[block_index].entries[entry_index].item;
}

operator [] :: (allocator: *BlockAllocator($T, $N), index: int) -> *T {
    block_index: int = index / N;
    entry_index: int = index % N;

    if !allocator.memory[block_index].entries[entry_index].active {
        return null;
    }

    return *allocator.memory[block_index].entries[entry_index].item;
}

get_first :: (allocator: BlockAllocator($T, $N)) -> *T {
    for *entry: allocator {
        return entry;
    }

    return null;
}

pop_first :: (allocator: BlockAllocator($T, $N)) -> T {
    for entry, entry_index: allocator {
        release(*allocator, entry_index);
        return entry;
    }

    return .{};
}

claim :: (allocator: *BlockAllocator($T, $N)) -> *T {
    entry: T;
    return claim(allocator, entry);
}

claim :: (allocator: *BlockAllocator($T, $N), entry: T) -> *T {
    if allocator.count >= allocator.memory.count * N {
        allocate_bucket(allocator);
    }

    for block_index: 0..allocator.memory.count - 1 {
        if allocator.memory[block_index].count == N {
            continue;
        }

        for entry_index: 0..N - 1 {
            if !allocator.memory[block_index].entries[entry_index].active {
                allocator.memory[block_index].entries[entry_index].active = true;
                allocator.memory[block_index].entries[entry_index].item = entry;
                allocator.memory[block_index].count += 1;
                allocator.count += 1;
                return *allocator.memory[block_index].entries[entry_index].item;
            }
        }
    }

    return null;
}

// useful for doing things like queues since buckets will automatically get moved to the end on release when they're empty
claim_end :: (allocator: *BlockAllocator($T, $N)) -> *T {
    entry: T;
    return claim_end(allocator, entry);
}

claim_end :: (allocator: *BlockAllocator($T, $N), entry: T) -> *T {
    if allocator.memory.count == 0 || allocator.memory[allocator.memory.count - 1].entries[N - 1].active {
        allocate_bucket(allocator);
    }

    last_empty_index := N - 1;
    for #v2 < entry_index: 0..N - 2 {
        if allocator.memory[allocator.memory.count - 1].entries[entry_index].active {
            break;
        }

        last_empty_index = entry_index;
    }

    allocator.memory[allocator.memory.count - 1].entries[last_empty_index].active = true;
    allocator.memory[allocator.memory.count - 1].entries[last_empty_index].item = entry;
    allocator.memory[allocator.memory.count - 1].count += 1;
    allocator.count += 1;
    return *allocator.memory[allocator.memory.count - 1].entries[last_empty_index].item;
}

release :: (allocator: *BlockAllocator($T, $N), entry: *T) {
    pointer := cast(*BlockEntry(T)) ((cast(*u8) entry) - BlockAllocator(T, N).ITEM_OFFSET);
    for block_index: 0..allocator.memory.count - 1 {
        entries_pointer := allocator.memory[block_index].entries.data;

        if pointer >= entries_pointer && pointer < entries_pointer + N {
            entry_index := cast(int) (pointer - entries_pointer);

            if allocator.memory[block_index].entries[entry_index].active {
                release(allocator, block_index * N + entry_index);
            }

            return;
        }
    }

    assert(false, "Could not find entry to free.");
}

release :: (allocator: *BlockAllocator($T, $N), index: int, $free_empty: bool = false) {
    block_index: int = index / N;
    entry_index: int = index % N;

    allocator.memory[block_index].entries[entry_index].active = false;
    allocator.memory[block_index].count -= 1;
    allocator.count -= 1;

    if allocator.memory[block_index].count <= 0 {
        #if free_empty {
            array_free(allocator.memory[block_index].entries,, allocator.allocator);
            allocator.memory[block_index].entries.data = null;
        }

        freed_entry := allocator.memory[block_index].entries;

        for i: block_index..allocator.memory.count - 2 {
            allocator.memory[i] = allocator.memory[i + 1];
        }
        allocator.memory[allocator.memory.count - 1].entries = freed_entry;

        allocator.memory.count -= 1;
    }
}

clear :: (allocator: *BlockAllocator($T, $N)) {
    entries: [N] BlockEntry(T);

    for block_index: 0..allocator.memory.count - 1 {
        memcpy(allocator.memory[block_index].entries.data, entries.data, size_of(type_of(entries)));
        allocator.memory[block_index].count = 0;
    }

    allocator.memory.count = 0;
    allocator.count = 0;
}

validate_empty :: (allocator: BlockAllocator($T, $N)) {
    for block_index: 0..allocator.memory.count - 1 {
        for entry_index: 0..N - 1 {
            assert(!memory[block_index].entries[entry_index].active, "Could not validate block allocator as empty.");
        }
    }
}

free :: (allocator: BlockAllocator($T, $N)) {
    for block: allocator.memory {
        array_free(block.entries,, allocator.allocator);
    }
    array_free(allocator.memory,, allocator.allocator);
}

#scope_file

allocate_bucket :: (allocator: *BlockAllocator($T, $N)) {
    if allocator.memory.allocated > allocator.memory.count {
        allocator.memory.count += 1;
    } else {
        array_resize(*allocator.memory, allocator.memory.count + 1,, allocator.allocator);
    }

    if allocator.memory[allocator.memory.count - 1].entries.data == null {
        allocator.memory[allocator.memory.count - 1].entries = NewArray(N, BlockEntry(T),, allocator.allocator);
    }
}

#import "Basic";

// #run {
//     allocator: BlockAllocator(int, 8);

//     claim(*allocator, 123);
//     two_three_four_pointer := claim(*allocator, 234);
//     claim(*allocator, 345);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     print("releasing 234\n");
//     release(*allocator, two_three_four_pointer);

//     print("count should be 2 %\n", allocator.count);
//     print("memory count should be 1 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     claim(*allocator, 456);
//     claim(*allocator, 567);
//     six_seven_eight_pointer := claim(*allocator, 678);
//     claim(*allocator, 789);
//     eight_nine_one_pointer := claim(*allocator, 891);
//     claim(*allocator, 123);

//     print("count should be 8 %\n", allocator.count);
//     print("memory count should be 1 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     release(*allocator, six_seven_eight_pointer);

//     print("count should be 7 %\n", allocator.count);
//     print("memory count should be 1 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     claim(*allocator, 234);
//     three_four_five_pointer := claim(*allocator, 345);

//     print("count should be 9 %\n", allocator.count);
//     print("memory count should be 2 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     release(*allocator, eight_nine_one_pointer);

//     print("count should be 8 %\n", allocator.count);
//     print("memory count should be 2 %\n", allocator.memory.count);

//     print("second bucket memory is %\n", allocator.memory[allocator.memory.count - 1].entries.data);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     release(*allocator, three_four_five_pointer);

//     print("count should be 7 %\n", allocator.count);
//     print("memory count should be 1 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     claim(*allocator, 456);
//     claim(*allocator, 567);

//     print("count should be 9 %\n", allocator.count);
//     print("memory count should be 2 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     print("second bucket memory is %\n", allocator.memory[allocator.memory.count - 1].entries.data);

//     while allocator.count > 0 {
//         release(*allocator, 0);
//     }

//     print("count should be 0 %\n", allocator.count);
//     print("memory count should be 0 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }

//     claim(*allocator, 123);

//     print("count should be 1 %\n", allocator.count);
//     print("memory count should be 1 %\n", allocator.memory.count);

//     for entry: allocator {
//         print("% %\n", entry, it_index);
//     }
// };
