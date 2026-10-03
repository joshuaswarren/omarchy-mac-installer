"""omarchy-migration: survey, export and import an Omarchy home."""

import sys

USAGE = """usage: omarchy-migration COMMAND [ARGS]

commands:
  survey     read-only summary of what a migration of this home would bring
  plan       review what importing an exported bundle would do
  apply      import a bundle according to a reviewed plan
  validate   check contract documents
  evidence   check a policy's evidence against a provider checkout
  fixture    synthetic exporter for integration development (capabilities, inventory, export)

Run 'omarchy-migration COMMAND --help' for a command's options."""


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else list(argv)
    if not arguments or arguments[0] in ("-h", "--help"):
        print(USAGE)
        return 0 if arguments else 2
    command, rest = arguments[0], arguments[1:]
    if command == "survey":
        from . import survey
        return survey.main(rest)
    if command in ("plan", "apply"):
        from . import review
        return review.main([command, *rest])
    if command == "validate":
        from . import contract
        return contract.main(["validate", *rest])
    if command == "evidence":
        from . import evidence
        return evidence.main(rest)
    if command == "fixture":
        from . import fixture
        return fixture.main(rest)
    print(f"omarchy-migration: unknown command '{command}'\n\n{USAGE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
