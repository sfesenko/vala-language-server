testclient_src = files([
  'testclient.vala',
])

executable('vls-testclient',
  dependencies: deps,
  sources: [testclient_src, extra_vala_sources],
  install: false)

unit_src = files([
  'unit.vala',
])

unit_exe = executable('vls-unit-test',
  dependencies: deps,
  sources: [unit_src, extra_vala_sources, foundation_vala_sources],
  install: false)

integration_src = files([
  'int_runner.vala',
  'int_helpers.vala',
  'int_core.vala',
  'int_navigation.vala',
  'int_semantictokens.vala',
  'int_editing.vala',
  'int_hierarchy.vala',
  'int_misc.vala',
  'int_log.vala',
  'int_golden.vala',
  'int_regression.vala',
  'int_perf.vala',
  'int_cancellation.vala',
])

int_exe = executable('vls-int-test',
  dependencies: deps,
  sources: [integration_src, extra_vala_sources],
  install: false)

# Register each GLib subtest as its own meson test so they are visible
# individually, grouped into the `int` and `unit` suites.
unit_tests = [
  '/vls/util/compare_versions',
  '/vls/util/get_string_pos',
  '/vls/util/count_chars_in_string',
  '/vls/util/get_arguments_from_command_str',
  '/vls/util/is_newline',
  '/vls/util/arg_is_vala_file',
  '/vls/util/serialize_roundtrip',
  '/vls/util/find_name_in_text',
  '/vls/util/line_byte_length',
  '/vls/util/is_decl_keyword',
  '/vls/util/delta_encode',
  '/vls/util/project_path',
  '/vls/util/project_uri',
  '/vls/foundation/scan_templates/empty',
  '/vls/foundation/scan_templates/no_templates',
  '/vls/foundation/scan_templates/simple',
  '/vls/foundation/scan_templates/single_interpolation',
  '/vls/foundation/scan_templates/shorthand_interpolation',
  '/vls/foundation/scan_templates/multiple_interpolations',
  '/vls/foundation/scan_templates/escaped_quote',
  '/vls/foundation/scan_templates/empty_template',
  '/vls/foundation/scan_templates/interpolation_only',
  '/vls/foundation/scan_templates/nested_parens',
  '/vls/foundation/scan_templates/multiple_templates',
  '/vls/foundation/response_builder/full',
  '/vls/foundation/response_builder/delta',
  '/vls/foundation/response_builder/delta_crash_regression',
]

foreach t : unit_tests
  test('unit' + t, unit_exe,
       args: ['-p', t],
       suite: 'unit')
endforeach

integration_tests = [
  '/int/publish_diagnostics',
  '/int/non_native_root_survives',
  '/int/initialize_capabilities',
  '/int/document_symbol',
  '/int/hover',
  '/int/goto_definition',
  '/int/hover_inside_plain_string_is_null',
  '/int/definition_inside_plain_string_is_null',
  '/int/hover_inside_interp_shows_var_type',
  '/int/definition_inside_interp_jumps_to_param',
  '/int/edit_interp_string_no_crash',
  '/int/range_formatting',
  '/int/completion',
  '/int/semantic_tokens_full',
  '/int/semantic_tokens_coverage',
  '/int/semantic_tokens_range',
  '/int/semantic_tokens_template_string',
  '/int/semantic_tokens_delta',
  '/int/references',
  '/int/document_highlight',
  '/int/inlay_hint',
  '/int/workspace_symbol',
  '/int/formatting',
  '/int/implementation',
  '/int/log_uses_project_path',
  '/int/golden/document_symbol',
  '/int/golden/goto_definition',
  '/int/golden/references',
  '/int/golden/document_highlight',
  '/int/golden/implementation',
  '/int/golden/hover',
  '/int/golden/rename',
  '/int/golden/prepare_rename',
  '/int/golden/completion',
  '/int/golden/semantic_tokens_full',
  '/int/golden/signature_help',
  '/int/golden/formatting',
  '/int/golden/workspace_symbol',
  '/int/golden/inlay_hint',
  '/int/golden/code_lens',
  '/int/golden/code_action',
  '/int/golden/prepare_type_hierarchy',
  '/int/golden/prepare_call_hierarchy',
  '/int/golden/range_formatting',
  '/int/regression/adversarial_smoke_template_string',
  '/int/regression/adversarial_smoke_single_dollar',
  '/int/regression/adversarial_smoke_inverted_ref',
  '/int/regression/adversarial_smoke_replace_eval',
  '/int/regression/enum_base_type_completion',
  '/int/regression/struct_inheritance_completion',
  '/int/regression/override_completion_with_existing_methods',
  '/int/perf/compile_latency',
  '/int/perf/semantic_tokens_latency',
  '/int/perf/recompilation_after_edit',
  '/int/perf/semantic_tokens_after_edit',
  '/int/perf/using_directives_survive_recompile',
  '/int/cancellation/rapid_edits_recover',
  '/int/cancellation/rapid_cancel',
]

foreach t : integration_tests
  test('int' + t, int_exe,
        args: ['-p', t],
        suite: 'int',
        env: ['VLS_SERVER_PATH=' + vls.full_path()])
endforeach

# Foundation unit tests: these exercise Vls.Foundation's helpers directly
# without spawning a subprocess. The foundation module is intentionally free
# of the LSP protocol layer, so it only needs a minimal source set
# (util + TextDocument) rather than the full server.
foundation_test_src = files([
  'int_foundation.vala',
])

foundation_exe = executable('vls-foundation-test',
  dependencies: deps,
  sources: [extra_vala_sources, foundation_vala_sources, foundation_test_src],
  install: false)

foundation_tests = [
  '/int_foundation/buffer_for',
  '/int_foundation/slice_sourceref',
  '/int_foundation/normalize_sourceref',
  '/int_foundation/position_from_sourceref',
  '/int_foundation/range_from_sourceref',
  '/int_foundation/offset_to_position',
]

foreach t : foundation_tests
  test('foundation' + t, foundation_exe,
        args: ['-p', t],
        suite: 'foundation')
endforeach
