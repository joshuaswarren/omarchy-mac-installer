# Read-only migration survey

`survey.py` shows what a migration of your own Try home would bring, using the real [Try policy](../migration_contract/policy/try-omarchy-e1a0dbe.json). It is the first part of the migration that runs against real data, and it is deliberately read-only:

- It lists directories and reads file metadata. It never opens a regular file, so no file contents are read.
- It never enters a credential store (SSH, GnuPG, keyrings, 1Password, Codex, Chromium, Brave) or a path the policy excludes; stores are reported by presence only.
- It never follows a link and never enters another filesystem, including the Mac shared folder at `/mnt/mac`.
- It writes nothing, runs as you (it refuses root and other accounts' homes), and sends nothing anywhere.

## Run it inside the Try VM

```bash
git clone --branch explore/try-omarchy-migration --depth 1 https://github.com/omacom/omarchy-mac-installer ~/migration-survey
cd ~/migration-survey
python3 -m Development.migration_bundle_probe.survey
```

To update an existing checkout, run `git -C ~/migration-survey pull` instead of cloning. The summary lists category sizes, credential stores found, files the policy excludes or would clean of Try additions, links into the Mac share, other filesystems, and anything unsupported or unreadable, with up to ten example paths each, and the largest entries, broken down three levels inside dot-folders such as `.local/share/mise`. Add `--json` for the `inventory/1` contract document instead. Remove `~/migration-survey` afterwards; the checkout is not part of your home's survey results unless you run it from there and leave it in place.

The summary is printed to your terminal only. It can contain file and folder names from your home; share it selectively.

## Categories

Entries are grouped by their top-level name ([`categories.py`](categories.py)): `files-and-projects` for visible folders and files, `configuration` for dotfiles and dot-directories, and `caches` for `~/.cache`, which is not selected by default. Applications, databases, containers and credential adapters are not surveyed yet.

## Limits

Counts describe what collection would export with every category selected and no credential store, except that transform targets are counted whole: the survey does not read them, so it cannot tell whether Try's additions are present. Hardlinked, special and owner-unreadable files are withheld as `unsupported`, matching collection. The survey stops after two million entries. A busy home can change while it runs; vanished entries are reported rather than treated as errors. Like the collector, it needs Linux for mount identity checks.
