# LibreTranslate -- offline machine translation API + web UI (translate.lab). Bakes the Argos
# language models in at build time (install_models.py filters to the codes below), so it translates
# with no network at runtime. Each direction is ~50-120 MB; all pairs pivot through English, so keep
# "en" in the list. Edit the codes to change which languages ship. Self-contained.
FROM libretranslate/libretranslate:latest
RUN ./venv/bin/python scripts/install_models.py --load_only_lang_codes "en,es,fr,de"
