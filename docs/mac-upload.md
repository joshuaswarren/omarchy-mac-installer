# Mac image upload

`.github/workflows/mac-upload.yml` uploads one image build (`mac-image.yml`'s artifact) to the release host. It is a reusable workflow (`workflow_call`) for the VM acceptance job to chain after a passing run, and can be dispatched by hand. The logic is `scripts/mac-upload.py`; `scripts/tests/test_mac_upload.py` tests it against a local destination.

## Inputs

| Input | Meaning |
|---|---|
| `image-artifact` | the image build's artifact name, which is the image name `omarchy-mac-<lane>-<YYYY.MM.DD>-<package set id>-<image id>`, whose image id must be the first 12 hex digits of `image-sha256` |
| `image-sha256` | the expected sha256 of the image zip |
| `image-run-id` | the run that uploaded the image artifact (empty: this run) |
| `dry-run` | default `true`; upload to a scratch release and delete it |
| `evidence-artifact` | the artifact holding `acceptance-evidence.json` ([format](mac-acceptance-evidence.md)); required unless dry-run |
| `evidence-run-id` | the run that uploaded the evidence (empty: this run) |
| `part-bytes` | dry run only: a smaller part size, to split a small test image |
| `make-public` | real upload only: publish the draft afterwards and output the catalog's inputs (below) |

Callers grant `contents: write`, `actions: read` and `attestations: read`.

## What a real upload does

1. Runs in the `publish` environment, which deploys only from `main`, and refuses any other ref itself too.
2. Refuses unless the image and evidence runs are this repository's `main`, not pull requests and (if they are other runs) successful, the evidence names the run it came from, the zip carries a build attestation from `mac-image.yml` on `main`, the evidence record carries an attestation from `mac-acceptance.yml` on `main` (a dry run only warns about either), the zip's sha256 is the expected one, and the evidence record passes for that sha256.
3. Stages the files: the zip in `<zip>.partNN` files of at most 1992294400 bytes (2 to 16 parts, the convention the app's catalog parser and `publish-m1-release` share; a zip that fits in one part is uploaded whole), `<zip>.sha256`, `installer_data.json`, `IMAGE`, `PROVENANCE`, `INSPECTION`, `inputs`, `acceptance-evidence.json`, and `SHA256SUMS` over all of them and the whole zip, uploaded last.
4. Lists the destination before writing anything. A file already there with the same bytes is skipped, so an identical re-upload (or a resumed one) is a no-op; a file with different bytes, or a file this upload doesn't have, refuses the whole upload.
5. Uploads the missing files, downloads every file back and checks its sha256.

The stopgap destination is a draft prerelease on omacom/omarchy-mac-installer, named and tagged after the image, never marked latest. Once it is published the job never adds to it. Only the zip is attested by the image build; the records beside it are trusted as part of the same artifact.

The image id in the name keeps releases one build each. Before it, the name carried only the package set id, so a rebuild of the same packages on the same UTC day (a builder fix, say) was named like the published release and its upload was refused at the first part with different bytes. Now the same bytes always go to the same release, and new bytes to a new one.

## Handing the image to the catalog

A draft's files can't be downloaded by the app or by the catalog job's remote checks. With `make-public` (the release pipeline, `mac-release-pipeline.yml`, sets it), a real upload then:

6. Publishes the draft as a prerelease, never latest (`mac-upload.py make-public`). The tag is created at the commit the draft was made from; a tag of that name naming another commit refuses before anything is published. Publishing again is a no-op.
7. Outputs the catalog's `payload` and `installer-data` inputs ([format](catalog-release.md#inputs)), built from the files it uploaded and verified (`mac-upload.py catalog-inputs`), and `evidence`, the record it checked.

So an image is downloadable from its release once it passes acceptance, before the owner approves a catalog that names it, as it will be on R2 (`v1/releases/<image>/` is public as soon as it is written). No catalog points at it until the owner approves.

## Dry run

The release is `dryrun-<image>-<run id>-<attempt>`. The job runs every step above against it (an image without evidence or attestation gets a warning instead of a refusal; evidence it is given is still checked), then confirms through the destination's listing that an identical re-upload would write nothing and a changed file would be refused, and deletes the scratch release, also from an `always()` step if the job fails. Only a `dryrun-` draft is ever deleted.

`mac-upload-dry-run.yml` runs this end to end with a small fake image (`scripts/tests/make-mac-upload-fixture.py`) and a fixture evidence record.

## Hosts

`host` picks the destination. The release pipeline defaults to `r2`, so edge publishes land on mac.omarchy.org; `mac-upload.yml` called or dispatched on its own, and `mac-upload-dry-run.yml`, default to `github-release`, which works from any branch.

| `host` | Where | Image | Public |
|---|---|---|---|
| `github-release` | a draft prerelease on omacom/omarchy-mac-installer named after the image | `.partNN` files under 2 GiB | once `make-public` publishes the draft |
| `r2` | `v1/releases/<image>/` in the `omarchy-mac` bucket (`vars.R2_BUCKET` overrides the name) | whole, one PUT of at most 5 GiB | as soon as it is written, at `https://mac.omarchy.org/v1/releases/<image>/` |

On R2 every file is written with `If-None-Match: *`, so R2 itself refuses to replace one, and with `Cache-Control: public, max-age=31536000, immutable`. Files are read back through the S3 API, and `SHA256SUMS` must also come back byte for byte from `mac.omarchy.org`, or the upload fails: that is the URL the catalog pins. `make-public` does nothing on R2. `catalog-inputs` gives `mac.omarchy.org` URLs.

The R2 credentials are the `publish` environment's `R2_ENDPOINT` (the account's S3 endpoint, `https://<account>.r2.cloudflarestorage.com`), `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`. Callers pass them by name. Because they live in `publish`, an R2 dry run runs in that environment too, so only from `main`. An R2 dry run writes to `dryrun/<release>/` in the bucket, outside the intended `v1/releases/` lock, with `Cache-Control: no-store` so the edge keeps nothing once it is deleted afterwards; only a `dryrun-` release under `dryrun/` is ever deleted. A real R2 upload is public as soon as it is written, and is meant to sit under a bucket lock on `v1/releases/` (the catalogs beside it, `v1/catalog-<channel>.signed.json`, are replaced in place and must stay outside any lock); the first real `host: r2` run was the switch.

Dispatch `mac-upload-dry-run.yml` with `host: r2` from `main` to check the credentials, the bucket and the public domain end to end with a small fake image.
