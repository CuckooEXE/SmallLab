# Stirling-PDF -- offline PDF toolbox with OCR (pdf.lab). Upstream ships only eng/deu/fra/por/chi_sim
# Tesseract data; this layer apt-installs extra tesseract-ocr-<lang> packs so OCR covers more
# languages with no network at runtime. Ubuntu 24.04 base; traineddata lands in
# /usr/share/tesseract-ocr/5/tessdata/. Edit the package list to change coverage (package names are
# hyphenated: chi-sim, chi-tra; tesseract-ocr-all adds every pack, ~1 GB+). Self-contained.
FROM stirlingtools/stirling-pdf:latest
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tesseract-ocr-spa \
        tesseract-ocr-ita \
        tesseract-ocr-rus \
        tesseract-ocr-jpn \
        tesseract-ocr-ara && \
    rm -rf /var/lib/apt/lists/*
