# LibreTranslate -- offline machine translation API + web UI (translate.lab). Bakes the Argos
# language models in at build time (install_models.py filters to the codes below), so it translates
# with no network at runtime. Each direction is ~50-120 MB; all pairs pivot through English, so keep
# "en" in the list. Edit the codes to change which languages ship. Self-contained.
# libretranslate/libretranslate:latest pinned 2026-06
FROM libretranslate/libretranslate@sha256:ecfee1ebb0f250898eb64f285ff6279913b0b028c9c4577752939ed7de809f1b
RUN ./venv/bin/python scripts/install_models.py --load_only_lang_codes "en,es,fr,de"
