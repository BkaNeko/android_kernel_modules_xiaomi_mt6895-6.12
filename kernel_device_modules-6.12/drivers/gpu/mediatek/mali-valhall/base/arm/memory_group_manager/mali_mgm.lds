SECTIONS {
	__patchable_function_entries : { *(__patchable_function_entries) }
	.text : {
		init_module.cfi_jt = . + 0xb68;
		memory_group_manager_probe.cfi_jt = . + 0xb70;
		memory_group_manager_remove.cfi_jt = . + 0xb78;
		example_mgm_alloc_page.cfi_jt = . + 0xb80;
		example_mgm_free_page.cfi_jt = . + 0xb88;
		example_mgm_get_import_memory_id.cfi_jt = . + 0xb90;
		example_mgm_vmf_insert_pfn_prot.cfi_jt = . + 0xb98;
		example_mgm_update_gpu_pte.cfi_jt = . + 0xba0;
		generic_file_llseek.cfi_jt = . + 0xba8;
		simple_attr_read.cfi_jt = . + 0xbb0;
		simple_attr_write.cfi_jt = . + 0xbb8;
		mgm_default_group_set.cfi_jt = . + 0xbc0;
		fops_mgm_default_group_open.cfi_jt = . + 0xbc8;
		simple_attr_release.cfi_jt = . + 0xbd0;
		fops_mgm_update_gpu_pte_open.cfi_jt = . + 0xbd8;
		fops_mgm_insert_pfn_open.cfi_jt = . + 0xbe0;
		fops_mgm_lp_size_open.cfi_jt = . + 0xbe8;
		fops_mgm_size_open.cfi_jt = . + 0xbf0;
		mgm_default_group_get.cfi_jt = . + 0xbf8;
		mgm_update_gpu_pte_get.cfi_jt = . + 0xc00;
		mgm_insert_pfn_get.cfi_jt = . + 0xc08;
		mgm_lp_size_get.cfi_jt = . + 0xc10;
		mgm_size_get.cfi_jt = . + 0xc18;
		cleanup_module.cfi_jt = . + 0xc20;
	}
}
