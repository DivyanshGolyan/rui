# Requires every Linux part the plan selected. Shared by check.yml's `linux` job
# (non-pull-request events) and `admission` (pull requests); both pass the same env.
set -e
test "$PLAN_RESULT" = success
# A compile-only build runs neither policy nor suites.
case "$COMPILE_ONLY" in
  true) RAN=skipped ;;
  false) RAN=success ;;
  *) echo 'Missing or invalid compile-only selection' >&2; exit 1 ;;
esac
case "$DRAFT_RUN:${CHANGE_KIND-normal}" in
  true:normal|true:documentation|false:documentation)
    test "$COMPILE_ONLY" = false
    test "$POLICY_RESULT" = skipped
    test "$TARGETS" = '[]'
    test "$COMPILE_TARGETS" = '[]'
    test "$SPLIT" = false
    test "$TYPECHECK" = false
    test "$PR_JOB" = false
    for result in "$PR_RESULT" "$BUILD_RESULT" "$UNIT_RESULT" "$NATIVE_RESULT" "$TYPECHECK_RESULT"; do
      test "$result" = skipped
    done
    exit 0 ;;
  false:normal) ;;
  *) echo 'Invalid draft run or change kind' >&2; exit 1 ;;
esac
case "$PR_JOB" in
  true)
    # The single PR job holds policy, compile and suites; nothing else runs.
    test "$COMPILE_ONLY" = false
    test "$PR_RESULT" = success
    test "$SPLIT" = false
    test "$TYPECHECK" = false
    for result in "$POLICY_RESULT" "$BUILD_RESULT" "$UNIT_RESULT" "$NATIVE_RESULT" "$TYPECHECK_RESULT"; do
      test "$result" = skipped
    done
    exit 0 ;;
  false) test "$PR_RESULT" = skipped ;;
  *) echo 'Missing or invalid PR job selection' >&2; exit 1 ;;
esac
test "$POLICY_RESULT" = "$RAN"
if [ "$SPLIT" = true ]; then test "$UNIT_RESULT" = success; else test "$UNIT_RESULT" = skipped; fi
case "$TYPECHECK" in
  true) test "$TYPECHECK_RESULT" = success ;;
  false) test "$TYPECHECK_RESULT" = skipped ;;
  *) echo 'Missing or invalid typecheck selection' >&2; exit 1 ;;
esac
if [ -n "$COMPILE_TARGETS" ] && [ "$COMPILE_TARGETS" != '[]' ]; then
  test "$BUILD_RESULT" = success
else
  test "$BUILD_RESULT" = skipped
fi
if [ -n "$TARGETS" ] && [ "$TARGETS" != '[]' ]; then
  test "$NATIVE_RESULT" = "$RAN"
else
  test "$NATIVE_RESULT" = skipped
fi
