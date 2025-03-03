set(TEST_PRIM_PURE_PIR_CASES
    test_prim_program
    test_prim_simpnet
    test_prim_custom_vjp
    test_prim_jit
    test_pir_prim_flags
    test_pir_prim_flags_v2
    test_sink_decomp
    test_prim_skip_dynamic
    test_prim_dynamic
    test_prim_jit_dynamic
    test_auto_recompute
    test_auto_recompute_dy2static
    test_prim_sub_graph_dynamic_shape
    test_decompose_control_flow)

foreach(target ${TEST_PRIM_PURE_PIR_CASES})
  py_test_modules(
    ${target}
    MODULES
    ${target}
    ENVS
    GLOG_v=1
    FLAGS_enable_pir_api=true
    FLAGS_prim_enable_dynamic=true)
endforeach()

py_test_modules(
  test_pir_prim_flags_v3
  MODULES
  test_pir_prim_flags_v3
  ENVS
  GLOG_v=1
  FLAGS_enable_pir_api=true
  FLAGS_prim_vjp_skip_default_ops=0)

set_tests_properties(test_auto_recompute PROPERTIES TIMEOUT 40)
set_tests_properties(test_auto_recompute_dy2static PROPERTIES TIMEOUT 40)

set(TEST_PRIM_PURE_PIR_CINN test_prim_rms_norm_st_shape
                            test_prim_flags_check_ops)

if(WITH_CINN)
  foreach(target ${TEST_PRIM_PURE_PIR_CINN})
    py_test_modules(
      ${target}
      MODULES
      ${target}
      ENVS
      GLOG_v=1
      FLAGS_group_schedule_tiling_first=true
      FLAGS_prim_check_ops=true
      FLAGS_enable_pir_api=true
      FLAGS_prim_enable_dynamic=true
      FLAGS_cinn_bucket_compile=True
      FLAGS_pir_apply_shape_optimization_pass=1)
    set_tests_properties(${target} PROPERTIES LABELS "RUN_TYPE=CINN")
  endforeach()
endif()

foreach(target ${TEST_PRIM_TRANS_PIR_CASES})
  py_test_modules(${target} MODULES ${target} ENVS GLOG_v=1
                  FLAGS_enable_pir_in_executor=true)
endforeach()
