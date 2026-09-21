PYTHON ?= python3
DATA_FLAGS ?=
FETCH_FLAGS ?=

.PHONY: fetch data test-data

# Network only for absent pinned inputs; verified existing files are reused.
fetch:
	$(PYTHON) -m scripts.etl fetch $(FETCH_FLAGS)

# Always offline. Run make fetch explicitly before the first build.
data:
	$(PYTHON) -m scripts.etl build --offline $(DATA_FLAGS)

test-data:
	$(PYTHON) -m unittest discover -s tests -v
