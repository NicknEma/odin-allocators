package allocators

import "base:runtime"

import "core:fmt"

import "core:mem"
import "core:mem/virtual"

data: [4096]byte

main :: proc() {
	
	err: runtime.Allocator_Error;
	
	//~ Allocator-independent
	
	{
		err = free(nil);  // Freeing 0 is allowed
		
		allow_break();
	}
	
	//~ Arena
	
	{
		arena: mem.Arena;
		mem.arena_init(&arena, data[:]);
		
		context.allocator = mem.arena_allocator(&arena);
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		err = free(ptr3); // Cannot free individual allocations. Nothing happens.
		free_all();       // Can only free everything.
		
		// @Incomplete: temp regions
		
		allow_break();
	}
	
	//~ Stack
	
	// Similar to an Arena, but each allocation has a header that allows freeing previous
	// allocations.
	
	{
		stack: mem.Stack;
		mem.stack_init(&stack, data[:]);
		
		context.allocator = mem.stack_allocator(&stack);
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		err = free(ptr3); // Free the latest allocation
		err = free(ptr1); // Free the entire stack (both ptr1 and ptr2 are freed)
		
		ptr4 := new(int);
		
		err = free(rawptr(uintptr(ptr4) + 1)); // Cannot free in the middle of an allocation. Nothing happens.
		
		allow_break();
	}
	
	//~ Small Stack
	
	// Stack in which each allocation has the smallest possible header.
	
	{
		stack: mem.Small_Stack;
		mem.small_stack_init(&stack, data[:]);
		
		context.allocator = mem.small_stack_allocator(&stack);
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		err = free(ptr3); // Free the latest allocation
		err = free(ptr1); // Free the entire stack
		
		allow_break();
	}
	
	//~ Scratch Allocator
	
	// A ring buffer which wraps back at the start and overwrites previous allocations. It also has a special `backing_allocator` to allocate blocks that would
	// otherwise be fragmented.
	
	{
		SCRATCH_ALLOCATOR_MAX_INTS :: 32;
		
		scratch: mem.Scratch_Allocator;
		mem.scratch_allocator_init(&scratch, SCRATCH_ALLOCATOR_MAX_INTS * size_of(int));
		
		context.allocator = mem.scratch_allocator(&scratch);
		
		// Small allocations are pushed into the ring buffer.
		// Too many allocations will wrap the ring buffer back to the start.
		for i in 0..<SCRATCH_ALLOCATOR_MAX_INTS + 4 {
			ptr := new(int); _ = ptr;
		}
		
		free_all();
		
		// A block too big to fit into the ring buffer will be allocated separately by the `backing_allocator`.
		huge_slice := make([]int, SCRATCH_ALLOCATOR_MAX_INTS * 2);
		
		free_all();
		
		// Here we half-fill the ring buffer, taking up half of its full capacity.
		// The second allocation would *technically* fit into the ring buffer, but it would get
		// fragmented, so it is allocated on the `backing_allocator`.
		// @Todo: Aparently not?
		for i in 0..<SCRATCH_ALLOCATOR_MAX_INTS/2 {
			ptr := new(int); _ = ptr;
		}
		full_slice := make([]int, SCRATCH_ALLOCATOR_MAX_INTS);
		
		mem.scratch_allocator_destroy(&scratch);
		
		allow_break();
	}
	
	//~ Buddy Allocator
	
	when false {
		buddy: mem.Buddy_Allocator;
		mem.buddy_allocator_init(&buddy, data[:], 4);
		
		ptr := mem.buddy_allocator_alloc(&buddy, 256, zeroed = true);
		mem.buddy_allocator_free(&buddy, ptr);
		
		context.allocator = mem.buddy_allocator(&buddy);
	}
	
	//~ Dynamic Pool
	
	//~ Mutex Allocator
	
	//~ Rollback Stack
	
	//~ Tracking Allocator
	
	{
		track: mem.Tracking_Allocator;
		mem.tracking_allocator_init(&track, context.allocator);
		context.allocator = mem.tracking_allocator(&track);
		
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map));
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location);
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array));
				for entry in track.bad_free_array {
					fmt.eprintf("- %p @ %v\n", entry.memory, entry.location);
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
		
		// These allocations will not be freed.
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		// These frees are trying to free memory that was never allocated.
		free(rawptr(uintptr(1)));
		free(rawptr(max(uintptr)));
		
		allow_break();
	}
	
	//~ Virtual Memory allocators
	
	// package mem/virtual makes uses of the fact that most Operating Systems implement Virtual Memory,
	// so that memory can be reserved and committed as 2 separate stages.
	
	// The Arena implementation present in mem/virtual offers 3 variants: Buffer, Static and Growing.
	
	//~ Virtual Arena: Buffer
	
	// Similar to mem.Arena, it is backed by a user-provided buffer.
	
	{
		arena: virtual.Arena;
		err = virtual.arena_init_buffer(&arena, data[:]);
		
		slice1, slice2: []byte;
		
		slice1, err = virtual.arena_alloc(&arena, 32,            align_of(u8)); // Allocate directly, without assigning to context.allocator
		slice2, err = virtual.arena_alloc(&arena, size_of(data), align_of(u8)); // Buffer Arenas do not grow: if the allocation is too big, it will fail and do nothing.
		
		virtual.arena_free_all(&arena);
		
		context.allocator = virtual.arena_allocator(&arena);
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		free_all();
		
		allow_break();
	}
	
	//~ Virtual Arena: Static
	
	// A static arena contains a single `Memory_Block` allocated with virtual memory.
	
	{
		RESERVE_SIZE :: virtual.DEFAULT_ARENA_STATIC_RESERVE_SIZE;
		
		arena: virtual.Arena;
		err = virtual.arena_init_static(&arena, reserved = RESERVE_SIZE, commit_size = virtual.DEFAULT_ARENA_STATIC_COMMIT_SIZE);
		
		slice1, slice2: []byte;
		
		slice1, err = virtual.arena_alloc(&arena, 32,           align_of(u8)); // Allocate directly, without assigning to context.allocator
		slice2, err = virtual.arena_alloc(&arena, RESERVE_SIZE, align_of(u8)); // Static Arenas do not grow: if the allocation is too big, it will fail and do nothing.
		
		// Resets the usage offset to 0, but does not release the memory to the OS.
		virtual.arena_free_all(&arena);
		
		// This releases *all* the memory back to the OS, even if it's a single block.
		virtual.arena_destroy(&arena);
		
		context.allocator = virtual.arena_allocator(&arena);
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		free_all();
		
		allow_break();
	}
	
	//~ Virtual Arena: Growing
	
	// A growing arena is a linked list of `Memory_Block`s allocated with virtual memory.
	
	{
		RESERVE_SIZE :: virtual.DEFAULT_ARENA_GROWING_MINIMUM_BLOCK_SIZE;
		
		arena: virtual.Arena;
		err = virtual.arena_init_growing(&arena, reserved = RESERVE_SIZE);
		
		slice1, slice2: []byte;
		
		slice1, err = virtual.arena_alloc(&arena, 32,           align_of(u8)); // Allocate directly, without assigning to context.allocator
		slice2, err = virtual.arena_alloc(&arena, RESERVE_SIZE, align_of(u8)); // Allocation is big but the Arena is `Growing`: so it grows to accomodate the new allocation.
		
		// Now the Arena could have multiple blocks; this releases all but the first memory block back to the OS.
		// I know, right? `free_all` does not actually free *all* of the blocks. Whatever.
		virtual.arena_free_all(&arena);
		
		// Releases all the memory, including the last block.
		virtual.arena_destroy(&arena);
		
		context.allocator = virtual.arena_allocator(&arena);
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		free_all();
		
		allow_break();
	}
	
	// virtual.Arena has customized versions of the builtin procedures make(), new() and such.
	
	{
		
	}
	
	//~ Default allocators
	
	//~ Arena for the Temp Allocator
	
	// This is a growing arena that is only used for the default temp allocator. It is recommended by
	// the documentation to prefer the one in mem/virtual.
	// I showcase it here for completeness' sake. The API is almost identical to the one in mem/virtual,
	// so I only show the bare minimum.
	
	{
		arena: runtime.Arena;
		err = runtime.arena_init(&arena, 256, context.allocator);
		
		slice: []u8;
		slice, err = runtime.arena_alloc(&arena, 64 * size_of(u8), align_of(u8));
		
		runtime.arena_destroy(&arena);
		
		allow_break();
	}
	
	//~ Default Temp Allocator
	
	// Wrapper for the runtime.Arena allocator.
	
	{
		def_temp: runtime.Default_Temp_Allocator;
		runtime.default_temp_allocator_init(&def_temp, 256, context.allocator);
		
		runtime.default_temp_allocator_destroy(&def_temp);
		
		allow_break();
	}
	
	//~ Heap Allocator
	
	// This allocator is not represented by a type, rather only by a series of procedures, as it
	// uses the global process' heap to perform allocations (eg. `HeapAlloc` on Windows).
	// It should probabily only be used by the default context's allocator. Just like before,
	// it is shown for completeness' sake.
	
	{
		ptr := runtime.heap_alloc(64, zero_memory = true);
		ptr  = runtime.heap_resize(ptr, 128);
		runtime.heap_free(ptr);
		
		context.allocator = runtime.heap_allocator();
		
		ptr1 := new(int);
		ptr2 := new(int);
		ptr3 := new(int);
		
		free_all();
		
		allow_break();
	}
	
	//~ Nil Allocator
	
	// The allocator that does nothing. It can be set as the default one by passing `-default-to-nil-allocator` to the compiler.
	
	{
		context.allocator = runtime.nil_allocator();
		
		ptr1 := new(int);
		ptr2 := new(int);
		
		free_all();
		
		allow_break();
	}
	
	//~ Panic Allocator
	
	// The allocator that panics on every meaningful operation. It can be set as the default one by passing `-default-to-panic-allocator` to the compiler.
	// It can be used, for example, to enforce another piece of code to explicitly set an allocator.
	
	{
		context.allocator = runtime.panic_allocator();
		
		allow_break();
	}
	
	allow_break();
}

allow_break :: proc() { ;; }
