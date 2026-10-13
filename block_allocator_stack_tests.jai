// From BlockAllocatorJai: /usr/local/bin/jai block_allocator_stack_tests.jai -quiet -import_dir ..
// Run with: python3 -c 'import subprocess; subprocess.run(["../.build/block_allocator_stack_tests/block_allocator_stack_tests"], check=True, timeout=30)'
#import "Basic";
#import "Compiler";
#import "Thread";
#import "POSIX";
#import "BlockAllocatorJai";

#assert(OS == .MACOS);

#if !#exists(BLOCK_ALLOCATOR_STACK_TEST_WORKSPACE) {
    #run,stallable {
        context.allocator = temp;
        current := get_current_workspace();
        set_build_options_dc(.{do_output = false}, current);
        workspace := compiler_create_workspace("BlockAllocator Stack Tests");
        options := get_build_options(workspace);
        options.output_type = .EXECUTABLE;
        options.output_executable_name = "block_allocator_stack_tests";
        options.output_path = tprint("%../.build/block_allocator_stack_tests/", #filepath);
        options.intermediate_path = options.output_path;
        import_paths: [..] string;
        array_add(*import_paths, tprint("%../", #filepath));
        for get_build_options(current).import_path array_add(*import_paths, it);
        options.import_path = import_paths;
        set_build_options(options, workspace);
        set_working_directory(#filepath);
        add_build_string("BLOCK_ALLOCATOR_STACK_TEST_WORKSPACE :: true;", workspace);
        add_build_file(tprint("%block_allocator_stack_tests.jai", #filepath), workspace);
    }
}

Large_Item :: struct {
    marker: int = 17;
    payload: [8192] u8;
}

reset_under_call_depth :: (allocator: *BlockAllocator(Large_Item, 64), seed: int) {
    // Room reset has other live locals/callers on the embedded worker stack.
    padding: [32768] u8;
    for *byte, index: padding byte.* = cast(u8) ((seed + index) % 256);
    clear(allocator);
    assert(padding[0] == cast(u8) seed && padding[32767] == cast(u8) ((seed + 32767) % 256));
}

run_allocator_stack_test :: (thread: *Thread) -> s64 {
    // Thread uses pthread_create with null attributes: the platform's default worker stack.
    stack_size := pthread_get_stacksize_np(pthread_self());
    assert(stack_size <= 1024 * 1024, "This regression needs a small default worker stack.");
    print("POSIX worker default stack: % bytes\n", stack_size);

    allocator: BlockAllocator(Large_Item, 64);
    allocator.allocator = context.allocator;
    saved_entries: [3] *BlockEntry(Large_Item);
    saved_memory: *Block(Large_Item);
    saved_capacity: int;

    for cycle: 0..3 {
        for index: 0..3 * 64 - 1 {
            item := claim(*allocator);
            assert(item != null);
            item.marker = cycle + 1;
            item.payload[0] = 1;
            item.payload[4096] = 2;
            item.payload[8191] = 3;
        }
        assert(allocator.count == 3 * 64);
        assert(allocator.memory.count == 3);

        if cycle == 0 {
            saved_capacity = allocator.memory.allocated;
            saved_memory = allocator.memory.data;
            for block_index: 0..2 {
                saved_entries[block_index] = allocator.memory[block_index].entries.data;
            }
        } else {
            assert(allocator.memory.allocated == saved_capacity);
            assert(allocator.memory.data == saved_memory);
            for block_index: 0..2 {
                assert(allocator.memory[block_index].entries.data == saved_entries[block_index]);
            }
        }

        if cycle == 2 {
            // Release each last bucket before moving to the previous one; default release retains it.
            block_index := 2;
            while block_index >= 0 {
                entry_index := 63;
                while entry_index >= 0 {
                    release(*allocator, block_index * 64 + entry_index);
                    entry_index -= 1;
                }
                block_index -= 1;
            }
            assert(allocator.count == 0);
            assert(allocator.memory.count == 0);
        } else {
            reset_under_call_depth(*allocator, cycle);
            assert(allocator.count == 0);
            assert(allocator.memory.count == 0);
            assert(allocator.memory.allocated == saved_capacity);
            assert(allocator.memory.data == saved_memory);
            for block_index: 0..2 {
                // memory.count is zero, so inspect retained capacity through its backing pointer.
                block := *allocator.memory.data[block_index];
                assert(block.entries.data == saved_entries[block_index]);
                assert(block.entries.count == 64);
                assert(block.count == 0);
                for entry_index: 0..63 {
                    entry := *block.entries[entry_index];
                    assert(!entry.active);
                    assert(entry.item.marker == 17);
                    for entry.item.payload assert(it == 0);
                }
            }
        }
    }

    // Reactivate retained buckets so the allocator's normal free routine visits all three.
    for index: 0..3 * 64 - 1 {
        item := claim(*allocator);
        assert(item != null);
        assert(item.marker == 17);
        assert(item.payload[0] == 0);
        assert(item.payload[8191] == 0);
    }
    assert(allocator.memory.allocated == saved_capacity);
    for block_index: 0..2 assert(allocator.memory[block_index].entries.data == saved_entries[block_index]);
    free(allocator);
    return 0;
}

main :: () {
    worker: Thread;
    assert(thread_init(*worker, run_allocator_stack_test));
    thread_start(*worker);
    assert(thread_is_done(*worker, -1));
    thread_deinit(*worker);
    print("BlockAllocator stack/reset regression passed.\n");
}
