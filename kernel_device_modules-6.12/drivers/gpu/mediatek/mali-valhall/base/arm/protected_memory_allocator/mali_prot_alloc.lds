SECTIONS {
	__patchable_function_entries : { *(__patchable_function_entries) }
	.text : {
		init_module.cfi_jt = . + 0xcb0;
		mtk_protected_memory_allocator_probe.cfi_jt = . + 0xcb8;
		protected_memory_allocator_remove.cfi_jt = . + 0xcc0;
		simple_pma_alloc_page.cfi_jt = . + 0xcc8;
		simple_pma_get_phys_addr.cfi_jt = . + 0xcd0;
		simple_pma_free_page.cfi_jt = . + 0xcd8;
		cleanup_module.cfi_jt = . + 0xce0;
	}
}
