# Seed tested local models

This tool imports existing, tested Whisper tiny, Parakeet V2, Cohere Transcribe 4-bit, and S1-mini artifacts through the app's `LocalStore` and `ModelLibrary`. It does not fetch model weights. Quit Amanuensis before running it.

First prepare isolated copies of the speech smoke-test folders and S1-mini GGUF under `/tmp`. The preparation script fetches the publisher/converter model cards and full license texts. S1-mini gets its pinned official LICENSE and NOTICE. Cohere's public converter card records provenance because the official weight repository requires access approval.

```bash
BuildSupport/SeedModels/prepare-fixtures.sh /tmp/amanuensis-seed-fixtures
```

The output directory must be new. To verify the import without touching application data:

```bash
BuildSupport/SeedModels/seed.sh \
  --sources /tmp/amanuensis-seed-fixtures \
  --destination /tmp/amanuensis-seed-test \
  --new-configuration
```

Once the actual runtime tests pass, seed the app's data directory explicitly:

```bash
BuildSupport/SeedModels/seed.sh \
  --sources /tmp/amanuensis-seed-fixtures \
  --destination "$HOME/Library/Application Support/Amanuensis" \
  --new-configuration
```

`--new-configuration` selects Parakeet V2 for each initial mode only when the database has no saved configuration row. It preserves the preset cleanup defaults, including S1-mini for Message, Mail, Notes, and Meeting. Omit the flag to preserve configuration even in an empty store. Existing saved configuration always wins, regardless of the flag.

Existing installed model IDs are preserved. If an existing installation is incomplete, seeding stops instead of replacing it. Repeating a successful seed does not duplicate weights or overwrite settings. Every successful import is persisted before proceeding, so a failed run can resume. ModelLibrary creates managed copies; the prepared source fixtures remain untouched.
