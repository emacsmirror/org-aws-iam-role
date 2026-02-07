# Tests

This directory contains ERT integration tests that exercise `org-aws-iam-role` end to end against AWS.
They fetch a real role, build the buffer, and (for the regression test) compare the generated buffer
to the golden file in `tests/fixtures/integration-e2e-test-output.org` after normalizing timestamps.

## Test Summary

- `org-aws-iam-role/get-full-basic-test` — Fetches the full role object from AWS and asserts it returns data.
- `org-aws-iam-role/construct-basic-test` — Builds the internal role struct from the fetched object.
- `org-aws-iam-role/populate-buffer-basic-test` — Populates a buffer with role details, waits for async fetches, and checks for expected headings.
- `org-aws-iam-role/regression-test-against-golden-file` — Runs the main view command and compares the buffer output to the golden file after normalizing timestamps.

## Run All Tests (Non-Interactive)

```sh
emacs -Q --batch -L . -l tests/integration-e2e-test.el -f ert-run-tests-batch-and-exit
```

## Run Interactively

1. Open Emacs in this repo.
2. `M-x ert`
3. Use `t` to run all tests, or filter with `org-aws-iam-role/`.

## Notes

- Tests require AWS access and use the profile `williseed-iam-tester` (set in the test file).
- The main regression test is `org-aws-iam-role/regression-test-against-golden-file`. Load/eval the package and test file before running it in an interactive session.
- The regression test can be finicky on first run; if it aborts, run it a second time.
- Tests wait ~15 seconds for async policy fetches; large roles can take a while to load.
