build:
  nix build --show-trace

test-bats: build test-bats-run

test-bats-run:
  just zz-tests_bats/test

test: test-bats
