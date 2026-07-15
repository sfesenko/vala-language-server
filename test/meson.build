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
  sources: [unit_src, extra_vala_sources],
  install: false)

integration_src = files([
  'integration.vala',
])

integration_exe = executable('vls-integration-test',
  dependencies: deps,
  sources: [integration_src],
  install: false)

# Register each GLib subtest as its own meson test so they are visible
# individually, grouped into the `unit` and `integration` suites.
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
]

foreach t : unit_tests
  test('unit' + t, unit_exe,
       args: ['-p', t],
       suite: 'unit')
endforeach

integration_tests = [
  '/vls/integration/publish_diagnostics',
  '/vls/integration/non_native_root_survives',
  '/vls/integration/initialize_capabilities',
  '/vls/integration/document_symbol',
  '/vls/integration/hover',
  '/vls/integration/goto_definition',
  '/vls/integration/range_formatting',
  '/vls/integration/completion',
  '/vls/integration/semantic_tokens_full',
  '/vls/integration/semantic_tokens_coverage',
]

foreach t : integration_tests
  test('integration' + t, integration_exe,
       args: ['-p', t],
       suite: 'integration',
       env: ['VLS_SERVER_PATH=' + vls.full_path()])
endforeach
